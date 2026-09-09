defmodule DispatchTrainerWeb.Router do
  use DispatchTrainerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DispatchTrainerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug DispatchTrainerWeb.Plugs.FetchUser
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", DispatchTrainerWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete

    # 录音访问受限; 脱敏导出仅授权用户
    get "/recordings/:id", RecordingController, :show
    post "/recordings/:id/export", RecordingController, :export
  end

  scope "/", DispatchTrainerWeb do
    pipe_through :browser

    live_session :authenticated,
      on_mount: [{DispatchTrainerWeb.UserAuth, :require_authenticated}] do
      live "/trainee/sessions/:id", TraineeLive.Call, :call
    end

    live_session :instructor,
      on_mount: [{DispatchTrainerWeb.UserAuth, :require_instructor}] do
      live "/instructor", InstructorLive.Index, :index
      live "/instructor/sessions/:id", InstructorLive.Console, :console
    end
  end
end
