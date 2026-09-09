defmodule DispatchTrainer.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :username, :string, null: false
      add :password_hash, :string, null: false
      add :display_name, :string
      # trainee | instructor | admin
      add :role, :string, null: false, default: "trainee"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:username])
    create index(:users, [:role])
  end
end
