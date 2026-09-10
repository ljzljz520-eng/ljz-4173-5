// 急救调度培训平台前端入口。
// LiveView + 自定义 Hook: Opus 音频经 WebSocket 二进制帧收发,
// 接收侧使用与服务端一致的抖动缓冲(seq 重排、去重、过迟丢弃)。
(function () {
  const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");

  // ---- 客户端抖动缓冲(与服务端 JitterBuffer 行为一致) ----
  class JitterBuffer {
    constructor(windowSize = 10) {
      this.window = windowSize;
      this.buffer = new Map();
      this.next = null;
      this.droppedLate = 0;
      this.droppedDup = 0;
    }
    push(seq, payload) {
      if (this.next === null) this.next = seq;
      if (this.buffer.has(seq)) { this.droppedDup++; return "duplicate"; }
      if (seq < this.next) { this.droppedLate++; return "late"; }
      this.buffer.set(seq, payload);
      return "stored";
    }
    pop() {
      if (this.next === null) return null;
      if (this.buffer.has(this.next)) {
        const p = this.buffer.get(this.next);
        this.buffer.delete(this.next);
        this.next++;
        return p;
      }
      if (this.buffer.size >= this.window) {
        const seq = Math.min(...this.buffer.keys());
        const p = this.buffer.get(seq);
        this.buffer.delete(seq);
        this.next = seq + 1;
        return p;
      }
      return null;
    }
  }

  // 与服务端 Audio.Packet 一致的二进制帧:
  // magic(16) | version(8) | seq(32) | sent_at_ms(32) | opus payload
  const MAGIC = 0xd15c;
  function encodePacket(seq, sentAtMs, opus) {
    const buf = new ArrayBuffer(9 + opus.byteLength);
    const view = new DataView(buf);
    view.setUint16(0, MAGIC);
    view.setUint8(2, 1);
    view.setUint32(3, seq);
    view.setUint32(7, sentAtMs);
    new Uint8Array(buf, 9).set(new Uint8Array(opus));
    return buf;
  }
  function decodePacket(data) {
    const view = new DataView(data);
    if (view.getUint16(0) !== MAGIC) return null;
    return { seq: view.getUint32(3), sentAtMs: view.getUint32(7), opus: data.slice(9) };
  }

  // 服务端来电者/背景声 PCM 推送帧:
  // magic(16)=0xD15D | kind(8) | flags(8) | frame_seq(32) | frame_ms(32) | s16le pcm(48k mono)
  const PCM_MAGIC = 0xd15d;
  const PCM_KIND_SPEECH = 1;
  const PCM_KIND_AMBIENCE = 2;

  function decodePcmFrame(data) {
    const view = new DataView(data);
    if (view.byteLength < 12 || view.getUint16(0) !== PCM_MAGIC) return null;
    const kind = view.getUint8(2);
    const frameMs = view.getUint32(7);
    const pcmBytes = new Int16Array(data.slice(12));
    return { kind, frameMs, pcm: pcmBytes };
  }

  // 简易 FIFO 播放队列: ScriptProcessor 按声卡节奏取 PCM,
  // 队列暂时为空时补零(不阻塞), 天然吸收网络抖动。
  class PcmPlayer {
    constructor(sampleRate) {
      this.sampleRate = sampleRate;
      this.queue = []; // Int16Array 帧
      this.cursor = 0;
      this.ctx = null;
      this.node = null;
      this.volume = 1.0;
    }
    ensure() {
      if (this.ctx) return;
      const Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) return;
      this.ctx = new Ctx({ sampleRate: this.sampleRate });
      const bufferSize = 4096;
      this.node = this.ctx.createScriptProcessor(bufferSize, 0, 1);
      this.gain = this.ctx.createGain();
      this.gain.gain.value = this.volume;
      this.node.onaudioprocess = (e) => this.pull(e);
      this.node.connect(this.gain);
      this.gain.connect(this.ctx.destination);
    }
    // 浏览器自动播放策略: 必须在用户手势里 resume
    unlock() {
      this.ensure();
      if (this.ctx && this.ctx.state === "suspended") this.ctx.resume();
    }
    enqueue(pcm, kind) {
      this.ensure();
      if (!this.ctx) return; // 无输出环境: 静默丢弃
      if (kind === PCM_KIND_AMBIENCE) {
        const scaled = new Int16Array(pcm.length);
        for (let i = 0; i < pcm.length; i++) scaled[i] = Math.round(pcm[i] * 0.6);
        this.queue.push(scaled);
      } else {
        this.queue.push(pcm);
      }
    }
    pull(e) {
      const out = e.outputBuffer.getChannelData(0);
      for (let i = 0; i < out.length; i++) {
        let sample = 0;
        while (this.queue.length) {
          const frame = this.queue[0];
          if (this.cursor < frame.length) { sample = frame[this.cursor++] / 32768; break; }
          this.queue.shift();
          this.cursor = 0;
        }
        out[i] = sample;
      }
      // 限制内存: 网络长期过快时丢弃最旧的待播帧
      if (this.queue.length > 200) this.queue.splice(0, this.queue.length - 200);
    }
    close() {
      try { this.node && this.node.disconnect(); } catch (_) {}
      try { this.ctx && this.ctx.close(); } catch (_) {}
      this.ctx = null;
    }
  }

  const Hooks = {};

  // 音频通话 Hook: 挂载在学员/教员通话页容器上
  Hooks.OpusAudio = {
    mounted() {
      const sessionId = this.el.dataset.sessionId;
      const token = this.el.dataset.token;
      if (!sessionId || !token || !window.Phoenix) return;

      const socket = new Phoenix.Socket("/socket", { params: { token } });
      socket.connect();
      this.channel = socket.channel("call:" + sessionId, {});
      this.jitter = new JitterBuffer(10);
      this.seq = 0;
      this.t0 = performance.now();
      // 来电者 PCM 音频(48k) → 可听见
      this.pcm = new PcmPlayer(48000);

      this.channel.onMessage((_event, payload) => {
        if (payload instanceof ArrayBuffer || payload instanceof Blob) {
          (payload instanceof Blob ? payload.arrayBuffer() : Promise.resolve(payload)).then((buf) => {
            // 优先识别服务端来电 PCM 帧(magic 0xD15D)
            const pcmFrame = decodePcmFrame(buf);
            if (pcmFrame) {
              this.pcm.enqueue(pcmFrame.pcm, pcmFrame.kind);
              return;
            }
            // 对端 Opus 麦克风帧(magic 0xD15C)
            const pkt = decodePacket(buf);
            if (pkt) {
              this.jitter.push(pkt.seq, pkt.opus);
              let out;
              while ((out = this.jitter.pop()) !== null) this.playOpus(out);
            }
          });
          return undefined;
        }
        return payload;
      });

      // 用户首次点击页面时解锁音频(浏览器自动播放策略)
      this._unlock = () => this.pcm.unlock();
      window.addEventListener("pointerdown", this._unlock, { once: true });
      window.addEventListener("keydown", this._unlock, { once: true });

      // 仅在学员已“接听”(会话进入 active/interrupted)后才加入通话,
      // 避免接通前就触发服务器的 join_call
      this._joined = false;
      if (this.el.dataset.active === "1") this.joinCall();
      else {
        this.el.addEventListener("click", () => this.joinCall(), { once: true });
        // LiveView 重渲染后 data-active 变为 1
        this._mo = new MutationObserver(() => {
          if (this.el.dataset.active === "1") this.joinCall();
        });
        this._mo.observe(this.el, { attributes: true, attributeFilter: ["data-active"] });
      }
    },
    joinCall() {
      if (this._joined) return;
      this._joined = true;
      this._mo && this._mo.disconnect();
      this.channel.join()
        .receive("ok", () => this.startCapture())
        .receive("error", (resp) => console.warn("call join failed", resp));
    },
    async startCapture() {
      if (!navigator.mediaDevices?.getUserMedia) return;
      try {
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
        // 优先 WebCodecs AudioEncoder(Opus); 不支持时退化为 MediaRecorder 分片
        if (typeof AudioEncoder !== "undefined") {
          this.encoder = new AudioEncoder({
            output: (chunk) => {
              const data = new ArrayBuffer(chunk.byteLength);
              chunk.copyTo(data);
              this.channel.push("audio", encodePacket(this.seq++, Math.round(performance.now() - this.t0), data));
            },
            error: (e) => console.warn("encoder error", e),
          });
          this.encoder.configure({ codec: "opus", sampleRate: 48000, numberOfChannels: 1, bitrate: 24000 });
          const track = stream.getAudioTracks()[0];
          const processor = new MediaStreamTrackProcessor({ track });
          const reader = processor.readable.getReader();
          const pump = async () => {
            const { value, done } = await reader.read();
            if (done) return;
            this.encoder.encode(value);
            value.close();
            pump();
          };
          pump();
        }
      } catch (e) {
        console.warn("audio capture unavailable", e);
      }
    },
    playOpus(opus) {
      // 对端真人麦克风 Opus 帧由 WebCodecs AudioDecoder 解码后送入同一 PCM 队列;
      // 无 WebCodecs 环境下来电者语音(PCM 帧)仍可正常听见。
      if (typeof AudioDecoder === "undefined") return;
      if (!this.opusDecoder) {
        this.opusDecoder = new AudioDecoder({
          output: (audioData) => {
            const n = Math.min(audioData.numberOfFrames, 48000);
            const down = new Float32Array(n);
            audioData.copyTo(down, { planeIndex: 0, frameCount: n });
            const s16 = new Int16Array(n);
            for (let i = 0; i < n; i++) s16[i] = Math.max(-1, Math.min(1, down[i])) * 32767;
            this.pcm.enqueue(s16, PCM_KIND_SPEECH);
            audioData.close();
          },
          error: (e) => console.warn("opus decoder error", e),
        });
        this.opusDecoder.configure({ codec: "opus", sampleRate: 48000, numberOfChannels: 1 });
      }
      if (this.opusDecoder.state === "configured") {
        this.opusDecoder.decode(new EncodedAudioChunk({
          type: "key", timestamp: 0, data: opus,
        }));
      }
    },
    destroyed() {
      window.removeEventListener("pointerdown", this._unlock);
      window.removeEventListener("keydown", this._unlock);
      this._mo && this._mo.disconnect();
      this.channel && this.channel.leave();
      this.pcm && this.pcm.close();
    },
  };

  function startLiveView() {
    if (!window.Phoenix || !window.LiveView) return false;
    const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
      params: { _csrf_token: csrfToken },
      hooks: Hooks,
    });
    liveSocket.connect();
    window.liveSocket = liveSocket;
    return true;
  }

  if (!startLiveView()) {
    // 等待 vendor 脚本加载
    document.addEventListener("DOMContentLoaded", startLiveView);
  }
})();
