defmodule DispatchTrainerWeb.InstructorConsoleTest do
  @moduledoc "教员控制台: 控制操作、隐藏条件可见性、逐项评分。"
  use DispatchTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import DispatchTrainer.SessionHelpers

  setup do
    session = session_fixture()
    session = DispatchTrainer.Sessions.get_session!(session.id)
    instructor = DispatchTrainer.Accounts.get_user!(session.instructor_id)
    trainee = DispatchTrainer.Accounts.get_user!(session.trainee_id)
    %{session: session, instructor: instructor, trainee: trainee}
  end

  test "未登录访问控制台被重定向到登录页", %{conn: conn, session: session} do
    assert {:error, {:redirect, %{to: "/login"}}} =
             live(conn, ~p"/instructor/sessions/#{session.id}")
  end

  test "学员访问教员控制台被重定向", %{conn: conn, session: session, trainee: trainee} do
    conn = log_in_user(conn, trainee)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/instructor/sessions/#{session.id}")
  end

  test "非主持教员不能查看或操作他人会话, 被重定向回控制台首页", %{conn: conn, session: session} do
    other_instructor = instructor_fixture()
    conn = log_in_user(conn, other_instructor)

    assert {:error, {:redirect, %{to: "/instructor"}}} =
             live(conn, ~p"/instructor/sessions/#{session.id}")
  end

  test "管理员可查看任意会话控制台", %{conn: conn, session: session} do
    admin = admin_fixture()
    assert {:ok, _view, html} =
             conn |> log_in_user(admin) |> live(~p"/instructor/sessions/#{session.id}")

    assert html =~ "演练控制台"
  end

  test "控制台显示隐藏条件、信息释放与分支按钮", %{
    conn: conn,
    session: session,
    instructor: instructor
  } do
    {:ok, view, html} = conn |> log_in_user(instructor) |> live(~p"/instructor/sessions/#{session.id}")

    assert html =~ "隐藏条件(仅教员)"
    assert html =~ "心梗高危-绝密标记"
    assert html =~ "真实地址(学员不可见)"
    assert html =~ "信息释放"
    assert html =~ "病情分支"

    # 接通后释放信息
    view |> element("button", "接通") |> render_click()
    assert render(view) =~ "active"

    view |> element("button[phx-value-key='history']") |> render_click()
    assert render(view) =~ "已释放"

    # 分支触发后显示已触发, 重复触发幂等
    view |> element("button[phx-value-key='worse']") |> render_click()
    assert render(view) =~ "已触发"
  end

  test "中断与恢复按钮更新状态", %{conn: conn, session: session, instructor: instructor} do
    {:ok, view, _html} =
      conn |> log_in_user(instructor) |> live(~p"/instructor/sessions/#{session.id}")

    view |> element("button", "接通") |> render_click()
    view |> element("button", "来电中断") |> render_click()
    assert render(view) =~ "interrupted"

    view |> element("button", "恢复通话") |> render_click()
    assert render(view) =~ "active"

    events = DispatchTrainer.Sessions.list_events(session.id)
    assert Enum.any?(events, &(&1.kind == "interrupt"))
    assert Enum.any?(events, &(&1.kind == "resume"))
  end

  test "学员端看不到隐藏条件与真实地址", %{
    conn: conn,
    session: session,
    trainee: trainee
  } do
    {:ok, _view, html} =
      conn |> log_in_user(trainee) |> live(~p"/trainee/sessions/#{session.id}")

    refute html =~ "心梗高危-绝密标记"
    refute html =~ "隐藏条件"
    refute html =~ "真实地址"
    refute html =~ session.scenario.true_address
  end

  test "学员端提问后看到来电者回应", %{conn: conn, session: session, trainee: trainee} do
    {:ok, view, _html} = conn |> log_in_user(trainee) |> live(~p"/trainee/sessions/#{session.id}")

    view |> element("button", "接听来电") |> render_click()

    view
    |> element("form[phx-submit='ask']")
    |> render_submit(%{question: "请问地址在哪里?"})

    html = render(view)
    assert html =~ "滨河路128号"
  end

  test "学员地址复述同音冲突时提示逐字确认", %{
    conn: conn,
    session: session,
    trainee: trainee
  } do
    {:ok, view, _html} = conn |> log_in_user(trainee) |> live(~p"/trainee/sessions/#{session.id}")
    view |> element("button", "接听来电") |> render_click()

    view
    |> element("form[phx-submit='confirm_address']")
    |> render_submit(%{address: "滨和路128号"})

    assert render(view) =~ "同音字差异"
  end

  test "通话结束后教员逐项评分", %{conn: conn, session: session, instructor: instructor} do
    {:ok, view, _html} =
      conn |> log_in_user(instructor) |> live(~p"/instructor/sessions/#{session.id}")

    view |> element("button", "接通") |> render_click()
    view |> element("button", "结束通话") |> render_click()
    assert render(view) =~ "逐项评分"

    view
    |> element("form")
    |> render_submit(%{
      "scores" => %{
        "confirm_address" => %{"score" => "18", "comment" => "逐字确认到位"},
        "identify_danger" => %{"score" => "16"},
        "instruct" => %{"score" => "15"}
      },
      "notes" => "表现良好"
    })

    html = render(view)
    assert html =~ "评分已保存"
    assert html =~ "49/60"

    evaluation = DispatchTrainer.Evaluations.get_evaluation_for_session(session.id)
    assert evaluation.total_score == 49
    assert evaluation.passed
  end
end
