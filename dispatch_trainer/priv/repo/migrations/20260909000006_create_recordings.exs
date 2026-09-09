defmodule DispatchTrainer.Repo.Migrations.CreateRecordings do
  use Ecto.Migration

  def change do
    create table(:recordings) do
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :path, :string, null: false
      add :format, :string, null: false, default: "ogg"
      add :duration_ms, :bigint, null: false, default: 0
      add :byte_size, :bigint, null: false, default: 0
      add :sha256, :string
      add :restricted, :boolean, null: false, default: true
      # 含敏感信息(姓名/电话/地址)的时间段, 用于脱敏导出
      add :pii_segments, {:array, :map}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:recordings, [:session_id])
  end
end
