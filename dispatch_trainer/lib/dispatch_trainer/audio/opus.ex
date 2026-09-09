defmodule DispatchTrainer.Audio.Opus do
  @moduledoc """
  Opus 帧级工具(RFC 6716 TOC 解析)。

  系统只对 Opus 包做帧级处理(校验、计数、静音替换),
  不解码音频内容, 也不对语音内容做任何医疗判断。
  """

  import Bitwise

  # RFC 6716 定义的 Opus 静音(PLC)包
  @silence <<0xF8, 0xFF, 0xFE>>

  # TOC config(高 5 位) → 单帧时长(毫秒, 48kHz)
  @frame_durations %{
    0 => 10, 1 => 20, 2 => 40, 3 => 60,
    4 => 10, 5 => 20, 6 => 40, 7 => 60,
    8 => 10, 9 => 20, 10 => 40, 11 => 60,
    12 => 10, 13 => 20, 14 => 10, 15 => 20,
    16 => 2.5, 17 => 5, 18 => 10, 19 => 20,
    20 => 2.5, 21 => 5, 22 => 10, 23 => 20,
    24 => 2.5, 25 => 5, 26 => 10, 27 => 20,
    28 => 2.5, 29 => 5, 30 => 10, 31 => 20
  }

  @doc "标准 Opus 静音包(20ms, 全频带)。"
  def silence, do: @silence

  @doc "校验包是否为结构合法的 Opus 包。"
  def validate(<<_toc, _rest::binary>> = packet) do
    if code(packet) == 3 and byte_size(packet) < 2 do
      {:error, :truncated}
    else
      :ok
    end
  end

  def validate(_), do: {:error, :empty}

  @doc "包内 Opus 帧数(按 TOC code 字段)。"
  def frame_count(<<toc, rest::binary>>) do
    case toc &&& 0x03 do
      0 -> 1
      1 -> 2
      2 -> 2
      3 when byte_size(rest) >= 1 -> :binary.first(rest) &&& 0x3F
      3 -> 0
    end
  end

  def frame_count(_), do: 0

  @doc "单帧时长(毫秒)。"
  def frame_duration_ms(<<toc, _::binary>>), do: Map.fetch!(@frame_durations, toc >>> 3)

  @doc "整包时长估计(毫秒)。"
  def duration_ms(packet) when byte_size(packet) >= 1 do
    frame_count(packet) * frame_duration_ms(packet)
  end

  defp code(<<toc, _::binary>>), do: toc &&& 0x03
end
