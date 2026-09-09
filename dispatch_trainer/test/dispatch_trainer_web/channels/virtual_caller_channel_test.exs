defmodule DispatchTrainerWeb.VirtualCallerChannelTest do
  @moduledoc "虚拟来电端频道: 提问应答、信息不全回避、分支重复触发幂等。"
  use DispatchTrainerWeb.ChannelCase, async: false

  setup do
    session = session_fixture()
    instructor = DispatchTrainer.Accounts.get_user!(session.instructor_id)
    %{session: session, instructor: instructor}
  end

  defp join_vc(user, session) do
    socket = connect_user_socket(user)
    subscribe_and_join(socket, DispatchTrainerWeb.VirtualCallerChannel, "virtual_caller:#{session.id}", %{})
  end

  test "开场白只含初始信息", %{session: session, instructor: instructor} do
    {:ok, _, socket} = join_vc(instructor, session)
    ref = push(socket, "greeting", %{})
    assert_reply ref, :ok, %{utterance: utterance}
    assert utterance =~ "胸口疼"
    refute utterance =~ "滨河路"
  end

  test "提问命中未释放信息时回避, 命中后释放并作答", %{session: session, instructor: instructor} do
    {:ok, _, socket} = join_vc(instructor, session)

    # 第一次提问: 触发 question 类释放, 同一轮即按已释放作答
    ref = push(socket, "ask", %{"text" => "请问地址在哪里?"})
    assert_reply ref, :ok, %{type: type, utterance: _utterance}
    assert type in ["answer", "withheld"]

    # 再次提问: 地址已释放, 必为 answer
    ref = push(socket, "ask", %{"text" => "地址是哪里?"})
    assert_reply ref, :ok, %{type: "answer", utterance: utterance}
    assert utterance =~ "滨河路128号"
  end

  test "未命中信息的提问返回 unknown", %{session: session, instructor: instructor} do
    {:ok, _, socket} = join_vc(instructor, session)
    ref = push(socket, "ask", %{"text" => "今天星期几"})
    assert_reply ref, :ok, %{type: "unknown"}
  end

  test "分支重复触发幂等", %{session: session, instructor: instructor} do
    {:ok, _, socket} = join_vc(instructor, session)

    ref = push(socket, "trigger_branch", %{"key" => "worse"})
    assert_reply ref, :ok, %{key: "worse", utterance: utterance}
    assert utterance =~ "喘不上气"

    ref = push(socket, "trigger_branch", %{"key" => "worse"})
    assert_reply ref, :error, %{reason: "already_triggered"}

    # 可重复分支不受限
    ref = push(socket, "trigger_branch", %{"key" => "outburst"})
    assert_reply ref, :ok, %{}
    ref = push(socket, "trigger_branch", %{"key" => "outburst"})
    assert_reply ref, :ok, %{}
  end

  test "学员不能加入虚拟来电端", %{session: session} do
    trainee = user_fixture()
    socket = connect_user_socket(trainee)

    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(
               socket,
               DispatchTrainerWeb.VirtualCallerChannel,
               "virtual_caller:#{session.id}",
               %{}
             )
  end
end
