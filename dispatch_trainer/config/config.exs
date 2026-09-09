# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :dispatch_trainer,
  ecto_repos: [DispatchTrainer.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :dispatch_trainer, DispatchTrainerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DispatchTrainerWeb.ErrorHTML, json: DispatchTrainerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: DispatchTrainer.PubSub,
  live_view: [signing_salt: "nQ003wnP"]

# 录音存储与实时会话配置
config :dispatch_trainer,
  recordings_dir: Path.expand("priv/recordings"),
  export_dir: Path.expand("priv/recordings/exports"),
  # 抖动缓冲窗口(包数)与 Opus 帧时长(毫秒)
  jitter_window: 10,
  opus_frame_ms: 20

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
