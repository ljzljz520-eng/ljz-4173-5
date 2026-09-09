defmodule DispatchTrainerWeb.UserSocket do
  @moduledoc "学员/教员 WebSocket 接入, 以 Phoenix.Token 识别用户。"
  use Phoenix.Socket

  channel "call:*", DispatchTrainerWeb.CallChannel
  channel "virtual_caller:*", DispatchTrainerWeb.VirtualCallerChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Phoenix.Token.verify(DispatchTrainerWeb.Endpoint, "user socket", token,
           max_age: 86_400
         ) do
      {:ok, user_id} -> {:ok, assign(socket, :user_id, user_id)}
      {:error, _reason} -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
