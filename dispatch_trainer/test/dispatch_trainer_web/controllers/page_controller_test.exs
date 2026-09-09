defmodule DispatchTrainerWeb.PageControllerTest do
  use DispatchTrainerWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "急救调度培训中心"
  end
end
