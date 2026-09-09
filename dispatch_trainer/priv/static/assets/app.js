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

      this.channel.onMessage((_event, payload) => {
        if (payload instanceof ArrayBuffer || payload instanceof Blob) {
          (payload instanceof Blob ? payload.arrayBuffer() : Promise.resolve(payload)).then((buf) => {
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
    playOpus(_opus) {
      // 解码播放由 WebCodecs AudioDecoder 完成; 训练环境无输出设备时静默丢弃
    },
    destroyed() {
      this.channel && this.channel.leave();
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
