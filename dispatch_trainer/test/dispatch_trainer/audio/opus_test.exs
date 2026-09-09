defmodule DispatchTrainer.Audio.OpusTest do
  use ExUnit.Case, async: true

  alias DispatchTrainer.Audio.Opus

  test "静音包合法且为 20ms 单帧" do
    assert :ok = Opus.validate(Opus.silence())
    assert Opus.frame_count(Opus.silence()) == 1
    assert Opus.duration_ms(Opus.silence()) == 20
  end

  test "TOC 解析: config 决定帧时长" do
    # config 0 (SILK NB 10ms), code 0
    assert Opus.frame_duration_ms(<<0x00, 0x00>>) == 10
    # config 3 (SILK NB 60ms)
    assert Opus.frame_duration_ms(<<0x18, 0x00>>) == 60
    # config 20 (CELT WB 2.5ms)
    assert Opus.frame_duration_ms(<<0xA0, 0x00>>) == 2.5
    # config 31 (CELT FB 20ms)
    assert Opus.frame_duration_ms(<<0xF8, 0x00>>) == 20
  end

  test "code 1/2 为双帧" do
    assert Opus.frame_count(<<0xF9, 0x00, 0x00>>) == 2
    assert Opus.frame_count(<<0xFA, 0x00, 0x00>>) == 2
  end

  test "code 3 从第二字节读取帧数" do
    # code 3, 帧数字节 = 5
    assert Opus.frame_count(<<0xFB, 0x05, 0x00>>) == 5
    # code 3 但缺帧数字节 → 截断
    assert {:error, :truncated} = Opus.validate(<<0xFB>>)
  end

  test "空包非法" do
    assert {:error, :empty} = Opus.validate(<<>>)
  end
end
