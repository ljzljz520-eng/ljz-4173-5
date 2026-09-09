defmodule DispatchTrainer.Repo.Migrations.CreateTimelineEvents do
  use Ecto.Migration

  def change do
    create table(:timeline_events) do
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      # 相对会话开始的真实毫秒偏移与墙上时钟
      add :at_ms, :bigint, null: false
      add :wall_time, :utc_datetime_usec, null: false
      # trainee | caller | instructor | system
      add :actor, :string, null: false
      add :kind, :string, null: false
      add :payload, :map, null: false, default: %{}

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:timeline_events, [:session_id, :at_ms])
    create index(:timeline_events, [:session_id, :kind])
  end
end
