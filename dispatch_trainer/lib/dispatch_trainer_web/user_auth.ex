defmodule DispatchTrainerWeb.UserAuth do
  @moduledoc "认证与授权: 控制器 plug 与 LiveView on_mount 钩子。"
  import Plug.Conn
  import Phoenix.Controller

  alias DispatchTrainer.Accounts
  alias DispatchTrainer.Accounts.User

  # ---- 控制器 ----

  def log_in_user(conn, %User{} = user) do
    conn
    |> put_session(:user_id, user.id)
    |> put_session(:live_socket_id, "users:#{user.id}")
    |> configure_session(renew: true)
  end

  def log_out_user(conn) do
    conn
    |> configure_session(drop: true)
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "请先登录。")
      |> redirect(to: "/login")
      |> halt()
    end
  end

  def require_instructor(conn, _opts) do
    case conn.assigns[:current_user] do
      %User{} = user ->
        if User.instructor?(user) do
          conn
        else
          conn
          |> put_flash(:error, "仅教员可访问该页面。")
          |> redirect(to: "/")
          |> halt()
        end

      nil ->
        conn
        |> put_flash(:error, "请先登录。")
        |> redirect(to: "/login")
        |> halt()
    end
  end

  # ---- LiveView on_mount ----

  def on_mount(:default, _params, session, socket) do
    {:cont, assign_current_user(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = assign_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  end

  def on_mount(:require_instructor, _params, session, socket) do
    socket = assign_current_user(socket, session)

    case socket.assigns.current_user do
      %User{} = user ->
        if User.instructor?(user) do
          {:cont, socket}
        else
          {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
        end

      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  end

  defp assign_current_user(socket, session) do
    user =
      case session["user_id"] do
        nil -> nil
        user_id -> Accounts.get_user(user_id)
      end

    Phoenix.Component.assign(socket, :current_user, user)
  end
end
