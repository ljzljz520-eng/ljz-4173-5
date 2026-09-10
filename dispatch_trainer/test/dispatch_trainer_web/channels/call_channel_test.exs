defmodule DispatchTrainerWeb.CallChannelTest do
  @moduledoc "通话频道: Opus 二进制帧、控制事件、权限与中断行为。"
  use DispatchTrainerWeb.ChannelCase, async: false

  alias DispatchTrainer.{Sessions, Sessions.SessionServer}
  alias DispatchTrainer.Audio.{Opus, Packet}

  setup do
    session = session_fixture()
    trainee = DispatchTrainer.Accounts.get_user!(session.trainee_id)
    instructor = DispatchTrainer.Accounts.get_user!(session.instructor_id)
    %{session: session, trainee: trainee, instructor: instructor}
  end

  defp join_call(user, session) do
    socket = connect_user_socket(user)
    subscribe_and_join(socket, DispatchTrainerWeb.CallChannel, "call:#{session.id}", %{})
  end

  test "学员与教员可加入, 无关用户被拒绝", %{session: session, trainee: trainee} do
    assert {:ok, _, _} = join_call(trainee, session)

    stranger = user_fixture()
    socket = connect_user_socket(stranger)
    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(socket, DispatchTrainerWeb.CallChannel, "call:#{session.id}", %{})

    # 非本会话教员同样被拒绝(不能旁听/操作他人会话)
    other_instructor = instructor_fixture()
    socket = connect_user_socket(other_instructor)
    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(socket, DispatchTrainerWeb.CallChannel, "call:#{session.id}", %{})
  end

  test "接通后来电者开场白作为可听见的语音帧与字幕推送", %{session: session, trainee: trainee} do
    {:ok, _, _socket} = join_call(trainee, session)

    # magic 0xD15D + speech kind(1)
    assert_push "audio", {:binary, <<0xD1, 0x5D, 1, _flags, _rest::binary>>}, 1_500
    assert_push "caller_speech", %{"kind" => "speech", "text" => text}, 500
    assert text =~ "急救中心"
  end

  test "学员不能执行任何教员控制动作", %{session: session, trainee: trainee} do
    {:ok, _, socket} = join_call(trainee, session)

    assert_reply push(socket, "release_info", %{"key" => "history"}), :error,
      %{reason: "forbidden_instructor_action"}

    assert_reply push(socket, "trigger_branch", %{"key" => "worse"}), :error,
      %{reason: "forbidden_instructor_action"}

    assert_reply push(socket, "end", %{}), :error,
      %{reason: "forbidden_instructor_action"}
  end

  test "学员仍可记录自己的提问/确认/指令", %{session: session, trainee: trainee} do
    {:ok, _, socket} = join_call(trainee, session)

    assert_reply push(socket, "log", %{"kind" => "instruction", "payload" => %{"text" => "平躺"}}),
                 :ok
  end

  test "学员提问后来电者回答以语音帧可听见", %{session: session, trainee: trainee} do
    {:ok, _, _socket} = join_call(trainee, session)
    {:ok, server} = SessionServer.ensure_started(session.id)

    # LiveView 的提问路径走 trainee_question(记录 + 释放 + 发声)
    Task.async(fn -> SessionServer.trainee_question(server, "地址在哪里?") end)

    # 开场白字幕之外, 必能收到包含地址内容的回答; 同时伴随 speech 语音帧
    deadline = System.monotonic_time(:millisecond) + 2_000
    {text, heard?} = wait_caption_with_audio("滨河路", deadline, false)
    assert text =~ "滨河路"
    assert heard?
  end

  # 持续消费字幕与语音帧, 直到字幕包含 expect 或超时
  defp wait_caption_with_audio(expect, deadline, heard?) do
    now = System.monotonic_time(:millisecond)

    cond do
      now > deadline ->
        flunk("未在 2s 内收到包含 #{expect} 的来电者语音")

      true ->
        receive do
          %Phoenix.Socket.Message{
            event: "caller_speech",
            payload: %{"text" => text}
          } ->
            if text =~ expect and heard?, do: {text, heard?}, else: wait_caption_with_audio(expect, deadline, heard?)

          %Phoenix.Socket.Message{
            event: "audio",
            payload: {:binary, <<0xD1, 0x5D, 1, _rest::binary>>}
          } ->
            wait_caption_with_audio(expect, deadline, true)
        after
          100 -> wait_caption_with_audio(expect, deadline, heard?)
        end
    end
  end

  test "教员触发背景声后学员收到 ambience 帧", %{
    session: session,
    trainee: trainee,
    instructor: instructor
  } do
    {:ok, _, _trainee_socket} = join_call(trainee, session)
    {:ok, _, _instructor_socket} = join_call(instructor, session)

    # 消费开场白
    assert_push "audio", {:binary, _}, 1_500

    {:ok, server} = SessionServer.ensure_started(session.id)
    assert {:ok, _audio} = SessionServer.play_background(server, "crying")

    # magic 0xD15D + ambience kind(2)
    assert_push "audio", {:binary, <<0xD1, 0x5D, 2, _rest::binary>>}, 1_500
  end

  test "Opus 二进制帧被接收并按序写入录音", %{session: session, trainee: trainee} do
    {:ok, _, socket} = join_call(trainee, session)

    for seq <- 0..2 do
      frame = Packet.encode(%Packet{seq: seq, sent_at_ms: seq * 20, payload: Opus.silence()})
      push(socket, "audio", {:binary, frame})
    end

    # 等待频道处理
    {:ok, server} = SessionServer.ensure_started(session.id)
    assert :ok = wait_until(fn -> SessionServer.state(server).recorded_packets == 3 end)
  end

  test "中断后音频帧被拒绝, 恢复后接受", %{
    session: session,
    trainee: trainee,
    instructor: instructor
  } do
    {:ok, _, trainee_socket} = join_call(trainee, session)
    {:ok, _, instructor_socket} = join_call(instructor, session)

    # 学员无权执行教员控制动作(中断)
    ref = push(trainee_socket, "interrupt", %{})
    assert_reply ref, :error, %{reason: "forbidden_instructor_action"}

    # 教员执行中断
    ref = push(instructor_socket, "interrupt", %{})
    assert_reply ref, :ok

    frame = Packet.encode(%Packet{seq: 0, sent_at_ms: 0, payload: Opus.silence()})
    ref = push(trainee_socket, "audio", {:binary, frame})
    assert_reply ref, :error, %{reason: "not_active"}

    # 学员同样不能恢复
    ref = push(trainee_socket, "resume", %{})
    assert_reply ref, :error, %{reason: "forbidden_instructor_action"}

    ref = push(instructor_socket, "resume", %{})
    assert_reply ref, :ok

    ref = push(trainee_socket, "audio", {:binary, frame})
    refute_reply ref, :error
  end

  test "log 事件按真实时间记录到时间线", %{session: session, trainee: trainee} do
    {:ok, _, socket} = join_call(trainee, session)

    ref = push(socket, "log", %{"kind" => "confirmation", "payload" => %{"type" => "address"}})
    assert_reply ref, :ok

    events = Sessions.list_events(session.id)
    assert Enum.any?(events, &(&1.kind == "confirmation" and &1.actor == "trainee"))
  end

  test "非法 log 类型被拒绝", %{session: session, trainee: trainee} do
    {:ok, _, socket} = join_call(trainee, session)
    ref = push(socket, "log", %{"kind" => "hack", "payload" => %{}})
    assert_reply ref, :error, %{reason: "invalid_kind"}
  end

  test "结束通话返回录音编号", %{session: session, instructor: instructor} do
    {:ok, _, socket} = join_call(instructor, session)
    frame = Packet.encode(%Packet{seq: 0, sent_at_ms: 0, payload: Opus.silence()})
    push(socket, "audio", {:binary, frame})

    ref = push(socket, "end", %{})
    assert_reply ref, :ok, %{recording_id: id}
    assert is_integer(id)
  end

  test "释放信息与分支触发经频道广播", %{session: session, instructor: instructor} do
    {:ok, _, socket} = join_call(instructor, session)

    ref = push(socket, "release_info", %{"key" => "history"})
    assert_reply ref, :ok
    assert_push "info_released", %{"key" => "history"}

    ref = push(socket, "trigger_branch", %{"key" => "worse"})
    assert_reply ref, :ok
    assert_push "branch_triggered", %{"key" => "worse"}

    # 重复触发: 幂等
    ref = push(socket, "trigger_branch", %{"key" => "worse"})
    assert_reply ref, :error, %{reason: "already_triggered"}
  end
end
