defmodule DispatchTrainer.Accounts do
  @moduledoc "用户账户上下文: 注册、认证、查询。"
  import Ecto.Query
  alias DispatchTrainer.Repo
  alias DispatchTrainer.Accounts.User

  def list_users do
    Repo.all(from u in User, order_by: [asc: u.id])
  end

  def list_trainees do
    Repo.all(from u in User, where: u.role == "trainee", order_by: [asc: u.username])
  end

  def get_user!(id), do: Repo.get!(User, id)
  def get_user(id), do: Repo.get(User, id)

  def get_user_by_username(username) when is_binary(username) do
    Repo.get_by(User, username: username)
  end

  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc "按用户名与口令认证; 失败时返回 {:error, :invalid_credentials}。"
  def authenticate(username, password) do
    user = get_user_by_username(username)

    cond do
      user && User.verify_password(password, user.password_hash) ->
        {:ok, user}

      user ->
        {:error, :invalid_credentials}

      true ->
        # 统一计时, 避免用户枚举
        User.verify_password(password, User.hash_password("dummy-password"))
        {:error, :invalid_credentials}
    end
  end
end
