defmodule DispatchTrainer.Accounts.User do
  @moduledoc """
  系统用户: 学员(trainee)、教员(instructor)、管理员(admin)。
  口令使用 PBKDF2-HMAC-SHA256 加盐散列, 不明文存储。
  """
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(trainee instructor admin)
  @pbkdf2_iterations 100_000

  schema "users" do
    field :username, :string
    field :password, :string, virtual: true
    field :password_hash, :string
    field :display_name, :string
    field :role, :string, default: "trainee"

    has_many :sessions_as_trainee, DispatchTrainer.Sessions.Session, foreign_key: :trainee_id
    has_many :sessions_as_instructor, DispatchTrainer.Sessions.Session,
      foreign_key: :instructor_id

    timestamps(type: :utc_datetime_usec)
  end

  def roles, do: @roles

  def instructor?(%__MODULE__{role: role}), do: role in ["instructor", "admin"]
  def admin?(%__MODULE__{role: "admin"}), do: true
  def admin?(_), do: false

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :password, :display_name, :role])
    |> validate_required([:username, :password, :role])
    |> validate_inclusion(:role, @roles)
    |> validate_length(:username, min: 3, max: 40)
    |> validate_format(:username, ~r/^[a-zA-Z0-9_.-]+$/)
    |> validate_length(:password, min: 8, max: 72)
    |> unique_constraint(:username)
    |> put_password_hash()
  end

  defp put_password_hash(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password -> put_change(changeset, :password_hash, hash_password(password))
    end
  end

  def hash_password(password) do
    salt = :crypto.strong_rand_bytes(16)
    hash = pbkdf2(password, salt)
    "pbkdf2$#{Base.encode16(salt, case: :lower)}$#{Base.encode16(hash, case: :lower)}"
  end

  def verify_password(password, "pbkdf2$" <> rest) when is_binary(password) do
    with [salt_b16, hash_b16] <- String.split(rest, "$"),
         {:ok, salt} <- Base.decode16(salt_b16, case: :lower),
         {:ok, expected} <- Base.decode16(hash_b16, case: :lower) do
      Plug.Crypto.secure_compare(pbkdf2(password, salt), expected)
    else
      _ -> false
    end
  end

  def verify_password(_, _), do: false

  defp pbkdf2(password, salt) do
    :crypto.pbkdf2_hmac(:sha256, password, salt, @pbkdf2_iterations, 32)
  end
end
