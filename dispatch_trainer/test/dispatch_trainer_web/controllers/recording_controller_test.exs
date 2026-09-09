defmodule DispatchTrainerWeb.RecordingControllerTest do
  @moduledoc "录音访问受限与脱敏导出端点。"
  use DispatchTrainerWeb.ConnCase, async: false

  import DispatchTrainer.SessionHelpers

  alias DispatchTrainer.Audio.Opus

  setup do
    session = session_fixture()
    {:ok, server} = start_server(session)
    :ok = DispatchTrainer.Sessions.SessionServer.join_call(server)

    for seq <- 0..4 do
      :ok =
        DispatchTrainer.Sessions.SessionServer.audio_packet(server, %DispatchTrainer.Audio.Packet{
          seq: seq,
          sent_at_ms: seq * 20,
          payload: Opus.silence()
        })
    end

    {:ok, _} =
      DispatchTrainer.Sessions.SessionServer.mark_pii(server, "address", 0, 60)

    {:ok, recording} = DispatchTrainer.Sessions.SessionServer.end_call(server, "instructor")

    instructor = DispatchTrainer.Accounts.get_user!(session.instructor_id)
    trainee = DispatchTrainer.Accounts.get_user!(session.trainee_id)

    %{session: session, recording: recording, instructor: instructor, trainee: trainee}
  end

  defp start_server(session) do
    DispatchTrainer.Sessions.SessionServer.ensure_started(session.id)
  end

  test "未登录访问录音被重定向", %{conn: conn, recording: recording} do
    conn = get(conn, ~p"/recordings/#{recording.id}")
    assert redirected_to(conn) == ~p"/login"
  end

  test "主持教员可下载录音", %{conn: conn, recording: recording, instructor: instructor} do
    conn = conn |> log_in_user(instructor) |> get(~p"/recordings/#{recording.id}")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "audio/ogg"
    assert conn.resp_body =~ "OggS"
  end

  test "学员与其他教员被拒绝(403)", %{conn: conn, recording: recording, trainee: trainee} do
    conn = conn |> log_in_user(trainee) |> get(~p"/recordings/#{recording.id}")
    assert conn.status == 403

    other = instructor_fixture()
    conn2 = build_conn() |> log_in_user(other) |> get(~p"/recordings/#{recording.id}")
    assert conn2.status == 403
  end

  test "脱敏导出返回替换静音后的音频", %{
    conn: conn,
    recording: recording,
    instructor: instructor
  } do
    conn = conn |> log_in_user(instructor) |> post(~p"/recordings/#{recording.id}/export")
    assert conn.status == 200
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "redacted"

    {:ok, %{packets: packets}} = DispatchTrainer.Audio.Ogg.demux(conn.resp_body)
    # PII 段 0..60ms → 前 3 个 20ms 包被静音
    assert Enum.take(packets, 3) == [Opus.silence(), Opus.silence(), Opus.silence()]
  end

  test "学员不能导出", %{conn: conn, recording: recording, trainee: trainee} do
    conn = conn |> log_in_user(trainee) |> post(~p"/recordings/#{recording.id}/export")
    assert conn.status == 403
  end
end
