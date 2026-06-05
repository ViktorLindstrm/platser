defmodule PlatserWeb.PageControllerTest do
  use PlatserWeb.ConnCase

  use ExUnitProperties

  describe "GET / (unauthenticated)" do
    test "renders the Platser landing page", %{conn: conn} do
      conn = get(conn, ~p"/")
      body = html_response(conn, 200)
      assert body =~ "Platser"
      assert body =~ "Get started"
      assert body =~ "Sign in"
    end

    test "shows join code form", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "join-code-form"
    end

    property "always returns 200 for any conn without current_user" do
      check all(_ <- StreamData.constant(nil)) do
        conn = build_conn() |> Plug.Conn.assign(:current_user, nil)
        conn = get(conn, ~p"/")
        assert html_response(conn, 200)
      end
    end
  end

  describe "GET / (authenticated)" do
    property "always redirects to /events for any truthy current_user assign" do
      non_nil_values =
        StreamData.one_of([
          StreamData.positive_integer(),
          StreamData.string(:alphanumeric, min_length: 1),
          StreamData.map_of(
            StreamData.atom(:alphanumeric),
            StreamData.integer(),
            max_length: 3
          )
        ])

      check all(current_user <- non_nil_values) do
        conn =
          build_conn()
          |> Plug.Conn.assign(:current_user, current_user)

        result = PlatserWeb.PageController.home(conn, %{})

        assert result.status == 302
        assert List.first(Plug.Conn.get_resp_header(result, "location")) == "/events"
      end
    end
  end

  describe "GET /join" do
    test "redirects to /join/:code when code param is present", %{conn: conn} do
      conn = get(conn, ~p"/join", code: "ABC123")
      assert redirected_to(conn) == ~p"/join/ABC123"
    end

    test "redirects to home with error when code param is missing", %{conn: conn} do
      conn = get(conn, ~p"/join")
      assert redirected_to(conn) == ~p"/"
    end

    test "redirects to home with error when code param is empty", %{conn: conn} do
      conn = get(conn, ~p"/join", code: "")
      assert redirected_to(conn) == ~p"/"
    end
  end
end
