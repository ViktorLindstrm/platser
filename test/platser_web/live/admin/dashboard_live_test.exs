defmodule PlatserWeb.Admin.DashboardLiveTest do
  use PlatserWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platser.Accounts.User

  # ── Helpers ──────────────────────────────────────────────────────────────────

  @spec create_user(String.t()) :: User.t()
  defp create_user(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "admin_test_#{tag}_#{n}@example.com",
          display_name: "Test #{tag} #{n}",
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end

  @spec create_superuser() :: User.t()
  defp create_superuser do
    user = create_user("superuser")

    {:ok, super_user} =
      Ash.update(user, %{superuser: true}, action: :set_superuser, authorize?: false)

    super_user
  end

  @spec sign_in_conn(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  defp sign_in_conn(conn, user) do
    {:ok, signed_in_user} =
      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(User, :password),
        :sign_in,
        %{email: user.email, password: "password123"},
        authorize?: false
      )

    signed_in_conn =
      conn
      |> put_private(:phoenix_endpoint, PlatserWeb.Endpoint)
      |> init_test_session(%{})
      |> PlatserWeb.AuthController.success(%{}, signed_in_user, signed_in_user.__metadata__.token)

    Phoenix.ConnTest.build_conn()
    |> put_private(:phoenix_endpoint, PlatserWeb.Endpoint)
    |> init_test_session(Map.get(signed_in_conn.private, :plug_session, %{}))
  end

  # ── Tests ─────────────────────────────────────────────────────────────────────

  describe "access control" do
    test "anonymous user is redirected to sign-in", %{conn: conn} do
      {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/admin/dashboard")
    end

    test "regular (non-superuser) user is redirected to sign-in", %{conn: conn} do
      user = create_user("regular")
      conn = sign_in_conn(conn, user)

      {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/admin/dashboard")
    end

    test "superuser can access the admin dashboard", %{conn: conn} do
      super_user = create_superuser()
      conn = sign_in_conn(conn, super_user)

      {:ok, view, _html} = live(conn, "/admin/dashboard")

      assert has_element?(view, "h1", "Admin Dashboard")
    end
  end

  describe "dashboard content" do
    setup %{conn: conn} do
      super_user = create_superuser()
      conn = sign_in_conn(conn, super_user)
      {:ok, view, _html} = live(conn, "/admin/dashboard")
      %{view: view}
    end

    test "shows platform totals section", %{view: view} do
      assert has_element?(view, "h2", "Platform Totals")
    end

    test "shows current activity section", %{view: view} do
      assert has_element?(view, "h2", "Current Activity")
    end

    test "shows VM performance section", %{view: view} do
      assert has_element?(view, "h2", "VM Performance")
    end

    test "shows trends section", %{view: view} do
      assert has_element?(view, "h2", "Trends")
    end

    test "shows error log section", %{view: view} do
      assert has_element?(view, "h2", "Error Log")
    end

    test "shows LiveDashboard link", %{view: view} do
      assert has_element?(view, "a", "LiveDashboard")
    end
  end
end
