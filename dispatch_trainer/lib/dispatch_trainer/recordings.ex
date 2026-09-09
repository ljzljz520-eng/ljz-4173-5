defmodule DispatchTrainer.Recordings do
  @moduledoc """
  录音上下文: 落盘、查询、受限访问与脱敏导出。

  脱敏导出将标记为敏感(PII)的时间段替换为 Opus 静音帧,
  并去除导出元数据中的姓名、电话、地址等字段。
  """
  import Ecto.Query
  alias DispatchTrainer.Repo
  alias DispatchTrainer.Audio.{Ogg, Opus}
  alias DispatchTrainer.Recordings.{Policy, Recording}
  alias DispatchTrainer.Sessions.Session

  @doc "录音存储目录(按环境配置)。"
  def recordings_dir do
    dir = Application.get_env(:dispatch_trainer, :recordings_dir)
    File.mkdir_p!(dir)
    dir
  end

  def export_dir do
    dir = Application.get_env(:dispatch_trainer, :export_dir)
    File.mkdir_p!(dir)
    dir
  end

  def get_recording!(id) do
    Recording
    |> Repo.get!(id)
    |> Repo.preload(:session)
  end

  def get_recording_for_session(session_id) do
    Repo.get_by(Recording, session_id: session_id)
  end

  def list_recordings do
    Repo.all(from r in Recording, order_by: [desc: r.id], preload: [:session])
  end

  @doc "通话结束时把按序 Opus 包封装为 Ogg 并落盘, 同时登记元数据。"
  def finalize_recording(%Session{id: session_id}, packets, opts) when is_map(opts) do
    ogg = Ogg.mux(packets)
    path = Path.join(recordings_dir(), "session-#{session_id}.ogg")
    File.write!(path, ogg)

    attrs = %{
      session_id: session_id,
      path: path,
      format: "ogg",
      duration_ms: Map.get(opts, :duration_ms, 0),
      byte_size: byte_size(ogg),
      sha256: sha256(ogg),
      pii_segments: Map.get(opts, :pii_segments, [])
    }

    %Recording{}
    |> Recording.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:path, :duration_ms, :byte_size, :sha256, :pii_segments]},
      conflict_target: :session_id
    )
  end

  @doc "读取录音文件内容(调用方须先经 Policy 授权)。"
  def read(%Recording{path: path}), do: File.read(path)

  @doc """
  生成脱敏导出:

    * PII 时间段内的音频帧替换为 Opus 静音
    * 导出元数据不含来电者姓名、电话、真实地址等敏感字段
    * 仅 Policy 授权用户可导出
  """
  def export_deidentified(%Recording{} = recording, user) do
    recording = Repo.preload(recording, session: [:scenario])

    if Policy.can_export?(user, recording, recording.session) do
      with {:ok, ogg} <- read(recording),
           {:ok, %{packets: packets}} <- Ogg.demux(ogg) do
        sanitized = silence_segments(packets, recording.pii_segments || [])
        export_ogg = Ogg.mux(sanitized)

        export_path =
          Path.join(export_dir(), "session-#{recording.session_id}-redacted.ogg")

        File.write!(export_path, export_ogg)

        {:ok,
         %{
           path: export_path,
           format: "ogg",
           duration_ms: recording.duration_ms,
           byte_size: byte_size(export_ogg),
           sha256: sha256(export_ogg),
           deidentified: true,
           redacted_ranges: recording.pii_segments || [],
           session_id: recording.session_id
         }}
      end
    else
      {:error, :forbidden}
    end
  end

  @doc "按累计帧时长把落在 PII 时间段内的包替换为静音。"
  def silence_segments(packets, segments) do
    ranges =
      Enum.map(segments, fn seg ->
        {to_int(seg["start_ms"] || seg[:start_ms]), to_int(seg["end_ms"] || seg[:end_ms])}
      end)

    {sanitized, _cursor} =
      Enum.map_reduce(packets, 0.0, fn packet, cursor ->
        duration = Opus.duration_ms(packet)
        range = {cursor, cursor + duration}

        replaced? =
          Enum.any?(ranges, fn {s, e} ->
            s != nil and e != nil and elem(range, 0) < e and elem(range, 1) > s
          end)

        packet_out = if replaced?, do: Opus.silence(), else: packet
        {packet_out, cursor + duration}
      end)

    sanitized
  end

  defp to_int(nil), do: nil
  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_binary(v), do: String.to_integer(v)

  defp sha256(data), do: Base.encode16(:crypto.hash(:sha256, data), case: :lower)
end
