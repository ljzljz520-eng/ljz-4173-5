defmodule DispatchTrainerWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use DispatchTrainerWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint DispatchTrainerWeb.Endpoint

      use DispatchTrainerWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import DispatchTrainerWeb.ConnCase
    end
  end

  setup tags do
    DispatchTrainer.DataCase.setup_sandbox(tags)
    DispatchTrainer.SessionHelpers.stop_all_session_servers_on_exit()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "以给定用户登录测试连接。"
  def log_in_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{user_id: user.id})
  end
end
