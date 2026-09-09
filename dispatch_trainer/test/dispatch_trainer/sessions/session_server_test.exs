defmodule DispatchTrainer.Sessions.SessionServerTest do
  @moduledoc """
  会话进程: 来电中断/恢复、分支重复触发幂等、
  信息逐步释放与真实时间事件记录。
  """
  use DispatchTrainer.DataCase, async: false

  import DispatchTrainer.SessionHelpers

  alias DispatchTrainer.{Sessions, Sessions.SessionServer}
  alias DispatchTrainer.Audio.Packet

  setup do
    session = session_fixture()
    pid = start_session_server!(session)
    :ok = SessionServer.join_call(pid)
    %{session: session, pid: pid}
  end

  describe "信息释放" do
    test "手动释放幂等: 重复释放返回 already_released 且只记录一次", %{pid: pid, session: s} do
      assert {:ok, release} = SessionServer.release_info(pid, "history")
      assert release.key == "history"
      assert {:error, :already_released} = SessionServer.release_info(pid, "history")

      events = Sessions.list_events(s.id) |> Enum.filter(&(&1.kind == "info_release"))
      assert Enum.count(events, &(&1.payload["key"] == "history")) == 1
    end

    test "定时释放在通话开始后按真实时间触发", %{pid: pid} do
      assert :ok = wait_until(fn -> MapSet.member?(SessionServer.state(pid).released, "age") end)
    end

    test "学员提问命中关键词自动释放对应信息", %{pid: pid} do
      refute MapSet.member?(SessionServer.state(pid).released, "address")
      assert {:answer, utterance, _release} = SessionServer.trainee_question(pid, "请问地址在哪里?")
      assert utterance =~ "滨河路128号"
      assert MapSet.member?(SessionServer.state(pid).released, "address")
    end

    test "未释放信息提问时来电者情绪化回避(信息不全)", %{pid: pid} do
      # “病史”为手动释放信息: 教员未释放前, 来电者情绪化回避, 不泄露内容
      assert {:withheld, utterance, release} =
               SessionServer.trainee_question(pid, "他以前有什么病史吗?")

      assert release.key == "history"
      refute utterance =~ "高血压"

      # 教员手动释放后按脚本作答
      assert {:ok, _} = SessionServer.release_info(pid, "history")

      assert {:answer, utterance, _release} =
               SessionServer.trainee_question(pid, "他以前有什么病史吗?")

      assert utterance =~ "高血压"
    end

    test "初始可用信息在接通时即释放", %{pid: pid} do
      assert MapSet.member?(SessionServer.state(pid).released, "complaint")
    end
  end

  describe "场景分支重复触发" do
    test "不可重复分支第二次触发幂等: 事件与释放不重复", %{pid: pid, session: s} do
      assert {:ok, branch} = SessionServer.trigger_branch(pid, "worse")
      assert branch.key == "worse"
      assert {:error, :already_triggered} = SessionServer.trigger_branch(pid, "worse")
      assert {:error, :already_triggered} = SessionServer.trigger_branch(pid, "worse")

      events = Sessions.list_events(s.id) |> Enum.filter(&(&1.kind == "branch_trigger"))
      assert Enum.count(events, &(&1.payload["key"] == "worse")) == 1

      releases = Sessions.list_events(s.id) |> Enum.filter(&(&1.kind == "info_release"))
      assert Enum.count(releases, &(&1.payload["key"] == "worse")) == 1
    end

    test "可重复分支允许多次触发并逐次记录", %{pid: pid, session: s} do
      assert {:ok, _} = SessionServer.trigger_branch(pid, "outburst")
      assert {:ok, _} = SessionServer.trigger_branch(pid, "outburst")

      events = Sessions.list_events(s.id) |> Enum.filter(&(&1.kind == "branch_trigger"))
      assert Enum.count(events, &(&1.payload["key"] == "outburst")) == 2
    end

    test "未知分支返回错误", %{pid: pid} do
      assert {:error, :unknown_branch} = SessionServer.trigger_branch(pid, "nope")
    end
  end

  describe "来电中断" do
    test "中断期间拒绝音频写入, 恢复后继续", %{pid: pid} do
      packet = %Packet{seq: 0, sent_at_ms: 0, payload: <<1, 2, 3>>}
      assert :ok = SessionServer.audio_packet(pid, packet)

      assert :ok = SessionServer.interrupt(pid, "instructor")
      assert SessionServer.state(pid).call_state == :interrupted
      assert {:error, :not_active} = SessionServer.audio_packet(pid, %Packet{seq: 1, payload: <<4>>})

      assert :ok = SessionServer.resume(pid, "instructor")
      assert SessionServer.state(pid).call_state == :active
      assert :ok = SessionServer.audio_packet(pid, %Packet{seq: 1, payload: <<4>>})
    end

    test "中断与恢复按真实时间记录, 中断计数累加", %{pid: pid, session: s} do
      :ok = SessionServer.interrupt(pid, "instructor")
      Process.sleep(5)
      :ok = SessionServer.resume(pid, "instructor")
      :ok = SessionServer.interrupt(pid, "instructor")
      :ok = SessionServer.resume(pid, "instructor")

      session = Sessions.get_session!(s.id)
      assert session.interrupt_count == 2

      events = Sessions.list_events(s.id)
      kinds = Enum.map(events, & &1.kind)
      assert Enum.count(kinds, &(&1 == "interrupt")) == 2
      assert Enum.count(kinds, &(&1 == "resume")) == 2

      # 时间线按真实时间单调递增且带墙上时钟
      ats = Enum.map(events, & &1.at_ms)
      assert ats == Enum.sort(ats)
      assert Enum.all?(events, &(&1.wall_time != nil))

      resume_event = Enum.find(events, &(&1.kind == "resume"))
      assert resume_event.payload["interrupted_ms"] >= 0
    end

    test "中断不丢失已释放信息与分支状态", %{pid: pid} do
      {:ok, _} = SessionServer.release_info(pid, "history")
      {:ok, _} = SessionServer.trigger_branch(pid, "worse")
      :ok = SessionServer.interrupt(pid, "instructor")

      state = SessionServer.state(pid)
      assert MapSet.member?(state.released, "history")
      assert MapSet.member?(state.triggered, "worse")

      :ok = SessionServer.resume(pid, "instructor")
      state = SessionServer.state(pid)
      assert MapSet.member?(state.released, "history")
      assert MapSet.member?(state.triggered, "worse")
    end

    test "非活动状态下中断返回错误", %{pid: pid} do
      :ok = SessionServer.interrupt(pid, "instructor")
      assert {:error, :not_active} = SessionServer.interrupt(pid, "instructor")
    end
  end

  describe "通话结束与录音" do
    test "结束时按序音频包封装为 Ogg 录音并登记元数据", %{pid: pid, session: s} do
      alias DispatchTrainer.Audio.Opus

      for seq <- 0..4 do
        :ok = SessionServer.audio_packet(pid, %Packet{seq: seq, sent_at_ms: seq * 20, payload: Opus.silence()})
      end

      assert {:ok, recording} = SessionServer.end_call(pid, "instructor")
      assert recording.session_id == s.id
      assert File.exists?(recording.path)
      assert recording.duration_ms > 0
      assert recording.sha256 != nil

      {:ok, %{packets: packets}} = DispatchTrainer.Audio.Ogg.demux(File.read!(recording.path))
      assert length(packets) == 5
      assert Enum.all?(packets, &(&1 == Opus.silence()))
    end

    test "结束后状态为 ended 且拒绝继续写入音频", %{pid: pid} do
      {:ok, _} = SessionServer.end_call(pid, "instructor")
      assert {:error, :not_active} = SessionServer.audio_packet(pid, %Packet{seq: 99, payload: <<1>>})
      assert Sessions.get_session!(pid |> SessionServer.state() |> Map.get(:session_id)).status == "ended"
    end
  end

  describe "真实时间时间线" do
    test "提问/确认/指令/教员触发均带 at_ms 与 wall_time", %{pid: pid, session: s} do
      {:ok, _} = SessionServer.log(pid, "trainee", "question", %{"text" => "地址?"})
      {:ok, _} = SessionServer.log(pid, "trainee", "confirmation", %{"type" => "address"})
      {:ok, _} = SessionServer.log(pid, "trainee", "instruction", %{"text" => "保持静卧"})
      {:ok, _} = SessionServer.release_info(pid, "history", "instructor")

      events = Sessions.list_events(s.id)
      kinds = Enum.map(events, & &1.kind)

      for kind <- ["question", "confirmation", "instruction", "info_release"] do
        assert kind in kinds
      end

      assert Enum.all?(events, fn e -> is_integer(e.at_ms) and e.at_ms >= 0 and e.wall_time end)
    end
  end
end
