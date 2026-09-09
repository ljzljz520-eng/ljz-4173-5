import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :dispatch_trainer, DispatchTrainer.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  database: "dispatch_trainer_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :dispatch_trainer, DispatchTrainerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Ad0Xh2cPHa1DIL2pmzkVllklqoE4dKgbepOK3nqaxrlPiCmQP0SHgns0zhWoKo3b",
  server: false

config :dispatch_trainer,
  recordings_dir: Path.expand("tmp/test_recordings"),
  export_dir: Path.expand("tmp/test_recordings/exports")

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
