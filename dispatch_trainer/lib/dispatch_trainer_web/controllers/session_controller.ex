defmodule DispatchTrainerWeb.SessionController do
  use DispatchTrainerWeb, :controller

  alias DispatchTrainer.Accounts
  alias DispatchTrainerWeb.UserAuth

  def new(conn, _params) do
    render(conn, :new, error_message: nil)
  end

  def create(conn, %{"user" => %{"username" => username, "password" => password}}) do
    case Accounts.authenticate(username, password) do
      {:ok, user} ->
        conn
        |> UserAuth.log_in_user(user)
        |> put_flash(:info, "已登录。")
        |> redirect(to: redirect_path(user))

      {:error, :invalid_credentials} ->
        conn
        |> put_flash(:error, "用户名或口令错误。")
        |> render(:new, error_message: "用户名或口令错误。")
    end
  end

  def delete(conn, _params) do
    conn
    |> UserAuth.log_out_user()
    |> put_flash(:info, "已退出登录。")
    |> redirect(to: "/login")
  end

  defp redirect_path(user) do
    if Accounts.User.instructor?(user), do: ~p"/instructor", else: ~p"/"
  end
end
