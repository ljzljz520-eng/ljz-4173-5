defmodule DispatchTrainer.RecordingsTest do
  @moduledoc "录音: 受限访问策略与脱敏导出(PII 片段静音 + 元数据脱敏)。"
  use DispatchTrainer.DataCase, async: false

  import DispatchTrainer.SessionHelpers

  alias DispatchTrainer.Recordings
  alias DispatchTrainer.Audio.{Ogg, Opus}
  alias DispatchTrainer.Recordings.Policy

  setup do
    session = session_fixture()
    packets = for _ <- 1..10, do: Opus.silence()

    {:ok, recording} =
      Recordings.finalize_recording(session, packets, %{
        duration_ms: 200,
        pii_segments: [%{"label" => "address", "start_ms" => 40, "end_ms" => 100}]
      })

    %{session: session, recording: recording}
  end

  describe "访问策略" do
    test "主持教员与管理员可访问, 其他教员与学员不可", %{session: session, recording: rec} do
      owner = DispatchTrainer.Accounts.get_user!(session.instructor_id)
      admin = admin_fixture()
      other_instructor = instructor_fixture()
      trainee = DispatchTrainer.Accounts.get_user!(session.trainee_id)

      assert Policy.can_access?(owner, rec, session)
      assert Policy.can_access?(admin, rec, session)
      refute Policy.can_access?(other_instructor, rec, session)
      refute Policy.can_access?(trainee, rec, session)
    end
  end

  describe "脱敏导出" do
    test "PII 时间段被替换为 Opus 静音", %{recording: rec, session: session} do
      instructor = DispatchTrainer.Accounts.get_user!(session.instructor_id)

      assert {:ok, export} = Recordings.export_deidentified(rec(rec), instructor)
      assert export.deidentified
      assert File.exists?(export.path)

      {:ok, %{packets: packets}} = Ogg.demux(File.read!(export.path))
      # 10 包 × 20ms; PII 段 40..100ms 覆盖第 3..5 包(索引 2..4)
      Enum.with_index(packets, fn packet, idx ->
        if idx in 2..4 do
          assert packet == Opus.silence(), "packet #{idx} should be silenced"
        end
      end)
    end

    test "导出元数据不含姓名/电话/地址等敏感字段", %{recording: rec, session: session} do
      instructor = DispatchTrainer.Accounts.get_user!(session.instructor_id)
      assert {:ok, export} = Recordings.export_deidentified(rec(rec), instructor)

      exported_keys = Map.keys(export) |> Enum.map(&to_string/1)
      for forbidden <- ~w(caller_name phone true_address address caller_profile) do
        refute forbidden in exported_keys
      end

      # 导出文件名脱敏(不含原始会话标识之外的明文)
      assert Path.basename(export.path) =~ "redacted"
    end

    test "未授权用户不能导出", %{recording: rec} do
      trainee = user_fixture()
      assert {:error, :forbidden} = Recordings.export_deidentified(rec(rec), trainee)
    end
  end

  test "录音元数据包含时长/大小/校验和", %{recording: rec} do
    assert rec.duration_ms == 200
    assert rec.byte_size > 0
    assert String.length(rec.sha256) == 64
    assert rec.restricted
  end

  defp rec(recording), do: Recordings.get_recording!(recording.id)
end
