defmodule DispatchTrainer.Recordings.Recording do
  @moduledoc "通话录音元数据。音频内容存于受控目录, 访问须经 Policy 授权。"
  use Ecto.Schema
  import Ecto.Changeset

  schema "recordings" do
    belongs_to :session, DispatchTrainer.Sessions.Session

    field :path, :string
    field :format, :string, default: "ogg"
    field :duration_ms, :integer, default: 0
    field :byte_size, :integer, default: 0
    field :sha256, :string
    field :restricted, :boolean, default: true
    field :pii_segments, {:array, :map}, default: []

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(recording, attrs) do
    recording
    |> cast(attrs, [
      :session_id,
      :path,
      :format,
      :duration_ms,
      :byte_size,
      :sha256,
      :restricted,
      :pii_segments
    ])
    |> validate_required([:session_id, :path, :format])
    |> unique_constraint(:session_id)
  end
end
