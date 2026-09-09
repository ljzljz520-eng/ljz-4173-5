defmodule DispatchTrainer.Audio.OggTest do
  use ExUnit.Case, async: true

  alias DispatchTrainer.Audio.{Ogg, Opus}

  test "封装/解析往返一致" do
    packets = [Opus.silence(), Opus.silence(), <<1, 2, 3>>]
    ogg = Ogg.mux(packets)

    assert {:ok, %{packets: decoded, duration_ms: duration}} = Ogg.demux(ogg)
    assert decoded == packets
    assert duration == 60
  end

  test "CRC 校验发现损坏" do
    ogg = Ogg.mux([Opus.silence()])
    <<head::binary-size(40), _byte, tail::binary>> = ogg
    corrupted = head <> <<255>> <> tail

    assert {:error, :bad_crc} = Ogg.demux(corrupted)
  end

  test "空包列表仍可封装出合法头" do
    ogg = Ogg.mux([])
    assert {:ok, %{packets: []}} = Ogg.demux(ogg)
  end

  test "大于 255 字节的包正确分段" do
    big = :binary.copy(<<0xF8>>, 600)
    ogg = Ogg.mux([big])
    assert {:ok, %{packets: [^big]}} = Ogg.demux(ogg)
  end

  test "granule 按帧时长累计" do
    ogg = Ogg.mux([Opus.silence(), Opus.silence()], frame_duration_ms: 20)
    assert {:ok, %{duration_ms: 40}} = Ogg.demux(ogg)
  end
end
