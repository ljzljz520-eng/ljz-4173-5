defmodule DispatchTrainer.Audio.CallerVoice do
  @moduledoc """
  来电者“语音”合成(确定性、无外部依赖, 不解码/不生成真实人声)。

  系统只负责把脚本文本转成**可听见的、带语言节奏特征的**音频:
    * 以音节为单元做基音(类似说话音高)频率调制, 配合振幅包络
    * 按标点停顿、按情绪(calm/anxious/panicked/hysterical)调速
    * 叠加呼吸/颤音等情绪色彩
    * 背景声(哭声/街道噪声等)由 `ambience/2` 单独合成

  产出 48kHz 单声道 S16LE PCM, 并按 20ms 帧分片。
  系统不对语音内容做任何识别或医疗判断, 脚本内容全部来自场景。
  """

  @sample_rate 48_000
  @frame_ms 20
  @frame_size div(@sample_rate * @frame_ms, 1000)
  @frame_bytes @frame_size * 2

  # PCM 推送帧: 2B magic | 1B kind | 1B flags | 4B frame_seq | 4B frame_ms | s16le pcm
  @magic 0xD15D
  @kind_speech 1
  @kind_ambience 2

  @doc "采样率(48kHz)。"
  def sample_rate, do: @sample_rate

  @doc "每帧采样数(20ms)。"
  def frame_size, do: @frame_size

  @doc """
  将来电者脚本文本合成为可听见的 PCM 帧列表。

  `emotion_level` 来自场景的 caller_profile。返回的二进制帧可直接
  经频道 "audio" 二进制事件推送, 由浏览器端 PCM 播放队列还原。
  """
  def speech_frames(text, emotion_level \\ "anxious") do
    pcm = render(text, emotion_level)
    encode_frames(pcm, @kind_speech, 0)
  end

  @doc "背景声 PCM 帧。key 取场景 background_audios 中的 key, volume 0..1。"
  def ambience_frames(key, duration_ms, volume \\ 0.6) when duration_ms > 0 do
    # 背景声只需可辨识, 限制合成长度以免占用过多 CPU
    capped = min(duration_ms, 10_000)
    pcm = render_ambience(key, capped, volume)
    encode_frames(pcm, @kind_ambience, 0)
  end

  @doc "合成完整 S16LE PCM(主要供测试)。"
  def render(text, emotion_level \\ "anxious") when is_binary(text) do
    cfg = emotion_config(emotion_level)
    # 情绪标记(如“(带着哭腔……)”)只是舞台提示, 不发声
    text = strip_stage_directions(text)
    units = tokenize(text)

    samples =
      Enum.flat_map(units, fn unit -> render_unit(unit, cfg) end)
      |> fade_in_out()

    for smp <- samples, into: <<>>, do: <<clamp_s16(smp)::16-little-signed>>
  end

  defp render_ambience(key, duration_ms, volume) do
    total = div(@sample_rate * duration_ms, 1000)

    samples =
      for i <- 0..(total - 1) do
        t = i / @sample_rate
        ambience_sample(key, t, volume)
      end

    for s <- samples, into: <<>>, do: <<clamp_s16(s)::16-little-signed>>
  end

  # ---- 合成参数 ----

  defp emotion_config("calm"),
    do: %{syllable_ms: 165, gap_ms: 45, pause_ms: 220, base: 135, spread: 14,
          tremolo_hz: 0.0, tremolo_depth: 0.0, vibrato_hz: 5.0, vibrato_depth: 2.0,
          jitter_ms: 4, amp: 0.5, breath: 0.0, rate_lo: 0.92, rate_hi: 1.08}

  defp emotion_config("anxious"),
    do: %{syllable_ms: 140, gap_ms: 32, pause_ms: 170, base: 150, spread: 22,
          tremolo_hz: 6.5, tremolo_depth: 0.07, vibrato_hz: 6.0, vibrato_depth: 4.0,
          jitter_ms: 12, amp: 0.58, breath: 0.5, rate_lo: 0.88, rate_hi: 1.12}

  defp emotion_config("hysterical"),
    do: %{syllable_ms: 108, gap_ms: 18, pause_ms: 120, base: 190, spread: 46,
          tremolo_hz: 9.0, tremolo_depth: 0.16, vibrato_hz: 7.5, vibrato_depth: 9.0,
          jitter_ms: 26, amp: 0.66, breath: 1.0, rate_lo: 0.78, rate_hi: 1.22}

  # panicked(默认): 语速快、音高偏高、带颤
  defp emotion_config(_),
    do: %{syllable_ms: 120, gap_ms: 24, pause_ms: 140, base: 172, spread: 30,
          tremolo_hz: 7.5, tremolo_depth: 0.11, vibrato_hz: 6.8, vibrato_depth: 6.0,
          jitter_ms: 18, amp: 0.62, breath: 0.7, rate_lo: 0.82, rate_hi: 1.18}

  # ---- 文本切分为“音节 + 停顿” ----

  defp tokenize(text) do
    text
    |> String.graphemes()
    |> Enum.chunk_while(
      [],
      fn g, acc ->
        cond do
          g in [" ", "\t", "\n", "\r"] ->
            {:cont, {:syllable, Enum.reverse(acc)}, []}

          g in ["，", ",", "、", "；", ";"] ->
            {:cont, [{:syllable, Enum.reverse(acc)}, {:pause, :short}], []}

          g in ["。", ".", "！", "!", "？", "?", "…"] ->
            {:cont, [{:syllable, Enum.reverse(acc)}, {:pause, :long}], []}

          true ->
            {:cont, [g | acc]}
        end
      end,
      fn acc -> {:cont, {:syllable, Enum.reverse(acc)}, []} end
    )
    |> List.flatten()
    |> Enum.filter(fn
      {:syllable, []} -> false
      _ -> true
    end)
  end

  defp strip_stage_directions(text) do
    text
    |> String.replace(~r/[（(][^）)]*[）)]/u, " ")
  end

  # ---- 逐单元渲染 ----

  defp render_unit({:pause, :short}, cfg), do: silence(cfg.pause_ms)
  defp render_unit({:pause, :long}, cfg), do: silence(cfg.pause_ms * 2)

  defp render_unit({:syllable, graphemes}, cfg) do
    # 一个汉字约一个音节; 连续拉丁字母按 4 个字母折一个音节
    syllable_count =
      graphemes
      |> Enum.map(&syllable_weight/1)
      |> Enum.sum()
      |> max(1)

    chars = Enum.join(graphemes)

    rate = cfg.rate_lo + :rand.uniform() * (cfg.rate_hi - cfg.rate_lo)
    jitter = (rem(:erlang.phash2(chars), 7) - 3) * cfg.jitter_ms / 6.0
    dur_ms = max(60, (cfg.syllable_ms + jitter) * syllable_count * rate)
    n = round(@sample_rate * dur_ms / 1000)

    # 每个音节有自己的目标音高, 形成语言的声调轮廓
    f0 = cfg.base + :erlang.phash2(chars <> "f0", 9) * cfg.spread / 4.0 - cfg.spread / 2

    syllable =
      for i <- 0..(n - 1) do
        t = i / @sample_rate
        phase = 2 * :math.pi() * f0 * t
        vibrato = 1 + cfg.vibrato_depth * :math.sin(2 * :math.pi() * cfg.vibrato_hz * t) / f0
        env = syllable_envelope(i / n)
        tremolo = 1 + cfg.tremolo_depth * :math.sin(2 * :math.pi() * cfg.tremolo_hz * t)

        voice =
          :math.sin(phase * vibrato) +
            0.45 * :math.sin(2 * phase * vibrato + 0.6) +
            0.18 * :math.sin(3 * phase * vibrato + 1.3)

        voice = voice / 1.6
        breath = cfg.breath * 0.05 * (:rand.uniform() * 2 - 1)

        (voice * env * tremolo + breath) * cfg.amp
      end

    syllable ++ silence(cfg.gap_ms)
  end

  defp syllable_weight(g) do
    if String.match?(g, ~r/[一-鿿]/u), do: 1.0, else: 0.25
  end

  # 软起/软落, 避免咔哒声
  defp syllable_envelope(u) do
    attack = min(u / 0.12, 1.0)
    release = min((1 - u) / 0.18, 1.0)
    min(attack, release)
  end

  defp silence(ms) do
    List.duplicate(0.0, round(@sample_rate * ms / 1000))
  end

  defp fade_in_out(samples) do
    n = length(samples)

    if n < 200 do
      samples
    else
      samples
      |> Enum.with_index()
      |> Enum.map(fn {s, i} ->
        f = min(min(i / 100, (n - 1 - i) / 300), 1.0)
        s * f
      end)
    end
  end

  # ---- 背景声 ----

  defp ambience_sample("crying", t, volume) do
    # 间歇性“抽泣”: 1.2s 周期的呼吸式起伏 + 颤抖基音
    cycle = :math.fmod(t, 2.4)
    sob =
      if cycle < 0.9 do
        u = cycle / 0.9
        env = :math.sin(:math.pi() * u)
        f = 320 + 50 * :math.sin(2 * :math.pi() * 5.5 * t)
        env * (0.7 * :math.sin(2 * :math.pi() * f * t) + 0.2 * :math.sin(2 * :math.pi() * f * 2 * t))
      else
        0.0
      end

    noise = 0.12 * (:rand.uniform() * 2 - 1)
    (sob * 0.8 + noise) * volume
  end

  defp ambience_sample("siren", t, volume) do
    # 警笛: 0.65Hz 在 600~900Hz 间扫频
    f = 750 + 150 * :math.sin(2 * :math.pi() * 0.65 * t)
    phase = 2 * :math.pi() * f * t
    (0.6 * :math.sin(phase) + 0.2 * :math.sin(2 * phase)) * volume
  end

  defp ambience_sample(_street_or_other, t, volume) do
    # 街道噪声: 低通感粉噪 + 偶发车辆隆隆声
    pink = pink_noise_sample()
    rumble_cycle = :math.fmod(t, 7.0)
    rumble = if rumble_cycle < 2.5,
      do: :math.sin(:math.pi() * rumble_cycle / 2.5) * 0.3 * :math.sin(2 * :math.pi() * 70 * t),
      else: 0.0
    (0.5 * pink + rumble) * volume
  end

  # 平滑白噪近似低通环境噪声(无需高质量, 只求可辨识)
  defp pink_noise_sample do
    0.7 * (:rand.uniform() * 2 - 1) + 0.3 * (:rand.uniform() * 2 - 1)
  end

  defp clamp_s16(s) do
    s |> Kernel.*(32_767) |> round() |> max(-32_768) |> min(32_767)
  end

  # ---- 帧编码 ----

  defp encode_frames(pcm, kind, flags) do
    pcm
    |> chunk_binary([])
    |> Enum.with_index()
    |> Enum.map(fn {chunk, idx} ->
      <<@magic::16, kind::8, flags::8, idx::32, @frame_ms::32, chunk::binary>>
    end)
  end

  defp chunk_binary(<<>>, acc), do: Enum.reverse(acc)
  defp chunk_binary(bin, acc) when byte_size(bin) <= @frame_bytes, do: Enum.reverse([bin | acc])

  defp chunk_binary(<<chunk::binary-size(@frame_bytes), rest::binary>>, acc),
    do: chunk_binary(rest, [chunk | acc])
end
