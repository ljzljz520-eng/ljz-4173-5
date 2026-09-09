defmodule DispatchTrainerWeb.ChannelCase do
  @moduledoc "频道测试用例: 提供沙箱与 socket 构造辅助。"
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import DispatchTrainerWeb.ChannelCase
      import DispatchTrainer.SessionHelpers

      @endpoint DispatchTrainerWeb.Endpoint
    end
  end

  setup tags do
    DispatchTrainer.DataCase.setup_sandbox(tags)
    DispatchTrainer.SessionHelpers.stop_all_session_servers_on_exit()
    :ok
  end

  require Phoenix.ChannelTest

  @endpoint DispatchTrainerWeb.Endpoint

  @doc "以指定用户建立已连接的 socket。"
  def connect_user_socket(user) do
    token = Phoenix.Token.sign(DispatchTrainerWeb.Endpoint, "user socket", user.id)
    {:ok, socket} = Phoenix.ChannelTest.connect(DispatchTrainerWeb.UserSocket, %{"token" => token})
    socket
  end
end
