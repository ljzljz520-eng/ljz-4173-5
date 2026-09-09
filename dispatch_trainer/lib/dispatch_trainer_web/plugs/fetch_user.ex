defmodule DispatchTrainerWeb.Plugs.FetchUser do
  @moduledoc "从会话加载当前用户到 conn.assigns.current_user。"
  import Plug.Conn
  alias DispatchTrainer.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    user =
      case get_session(conn, :user_id) do
        nil -> nil
        user_id -> Accounts.get_user(user_id)
      end

    assign(conn, :current_user, user)
  end
end
