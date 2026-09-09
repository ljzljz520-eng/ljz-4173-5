defmodule DispatchTrainer.Repo do
  use Ecto.Repo,
    otp_app: :dispatch_trainer,
    adapter: Ecto.Adapters.Postgres
end
