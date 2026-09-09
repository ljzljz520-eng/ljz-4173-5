defmodule DispatchTrainerWeb.RecordingController do
  @moduledoc "录音下载与脱敏导出。访问受 Recordings.Policy 限制。"
  use DispatchTrainerWeb, :controller

  alias DispatchTrainer.Recordings
  alias DispatchTrainer.Recordings.Policy

  plug :require_authenticated_user

  defp require_authenticated_user(conn, _opts) do
    DispatchTrainerWeb.UserAuth.require_authenticated_user(conn, [])
  end

  def show(conn, %{"id" => id}) do
    recording = Recordings.get_recording!(id)
    user = conn.assigns.current_user

    if Policy.can_access?(user, recording, recording.session) do
      conn
      |> put_resp_content_type("audio/ogg")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="session-#{recording.session_id}.ogg")
      )
      |> send_file(200, recording.path)
    else
      forbidden(conn)
    end
  end

  def export(conn, %{"id" => id}) do
    recording = Recordings.get_recording!(id)
    user = conn.assigns.current_user

    case Recordings.export_deidentified(recording, user) do
      {:ok, export} ->
        conn
        |> put_resp_content_type("audio/ogg")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="session-#{recording.session_id}-redacted.ogg")
        )
        |> send_file(200, export.path)

      {:error, :forbidden} ->
        forbidden(conn)

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  defp forbidden(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "forbidden")
    |> halt()
  end
end
