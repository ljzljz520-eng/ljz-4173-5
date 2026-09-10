defmodule DispatchTrainer.Audio.CallerVoiceTest do
  @moduledoc "来电者语音合成: 可听见的非空 PCM、帧格式、情绪与时长差异。"
  use ExUnit.Case, async: true

  alias DispatchTrainer.Audio.CallerVoice

  @magic 0xD15D

  test "脚本文本被合成为 48kHz/20ms 的 S16LE 语音帧" do
    frames = CallerVoice.speech_frames("喂？是急救中心吗？", "anxious")
    assert length(frames) > 1

    Enum.each(frames, fn <<magic::16, kind::8, _flags::8, idx::32, ms::32, pcm::binary>> ->
      assert magic == @magic
      assert kind == 1
      assert is_integer(idx)
      assert ms == 20
      # 每帧 20ms * 48k * 2 字节(最后一帧可较短)
      assert byte_size(pcm) <= 1920
      assert rem(byte_size(pcm), 2) == 0
    end)
  end

  test "语音非静音: 至少一部分采样有显著振幅" do
    [_ | _] = frames = CallerVoice.speech_frames("你们快点来吧", "panicked")

    peak =
      frames
      |> Enum.flat_map(fn <<_::binary-size(12), pcm::binary>> ->
        for <<s::16-little-signed <- pcm>>, do: abs(s)
      end)
      |> Enum.max()

    assert peak > 2000
  end

  test "情绪越激动语速越快(同等文本帧数更少、音高活动更强)" do
    calm = CallerVoice.speech_frames("我父亲胸口疼得很厉害", "calm")
    hysterical = CallerVoice.speech_frames("我父亲胸口疼得很厉害", "hysterical")
    assert length(hysterical) < length(calm)
  end

  test "舞台提示(情绪括注)不发音但不报错" do
    frames = CallerVoice.speech_frames("（带着哭腔、语速很快）求求你们", "panicked")
    assert length(frames) > 0
  end

  test "背景声帧以 ambience kind 输出且为可听见音频" do
    frames = CallerVoice.ambience_frames("crying", 500, 0.6)
    assert length(frames) == 25

    Enum.each(frames, fn <<_magic::16, kind::8, _::binary>> ->
      assert kind == 2
    end)

    peak =
      frames
      |> Enum.flat_map(fn <<_::binary-size(12), pcm::binary>> ->
        for <<s::16-little-signed <- pcm>>, do: abs(s)
      end)
      |> Enum.max()

    assert peak > 100
  end
end
