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

  test "中断后音频帧被拒绝, 恢复后接受", %{session: session, trainee: trainee} do
    {:ok, _, socket} = join_call(trainee, session)

    ref = push(socket, "interrupt", %{})
    assert_reply ref, :ok

    frame = Packet.encode(%Packet{seq: 0, sent_at_ms: 0, payload: Opus.silence()})
    ref = push(socket, "audio", {:binary, frame})
    assert_reply ref, :error, %{reason: "not_active"}

    ref = push(socket, "resume", %{})
    assert_reply ref, :ok

    ref = push(socket, "audio", {:binary, frame})
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
