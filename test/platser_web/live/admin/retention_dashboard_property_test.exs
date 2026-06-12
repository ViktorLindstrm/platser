defmodule PlatserWeb.Admin.RetentionDashboardPropertyTest do
  use PlatserWeb.ConnCase, async: false
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias Platser.Accounts.User
  alias Platser.Privacy.RetentionRun

  property "admin dashboard exposes generated retention run outcomes" do
    check all(
            status <- StreamData.member_of([:completed, :failed]),
            count <- StreamData.integer(0..5),
            max_runs: 5
          ) do
      started_at = DateTime.utc_now(:second)
      failure_reason = if status == :failed, do: "retention cleanup failed", else: nil

      {:ok, _run} =
        RetentionRun
        |> Ash.Changeset.for_create(
          :record,
          %{
            status: status,
            started_at: started_at,
            completed_at: started_at,
            cutoffs: %{"check_ins" => DateTime.to_iso8601(started_at)},
            outcome_counts: %{"check_ins_anonymized" => count},
            failure_reason: failure_reason
          },
          authorize?: false
        )
        |> Ash.create()

      conn = sign_in_conn(build_conn(), create_superuser())
      {:ok, view, _html} = live(conn, "/admin/dashboard")

      assert has_element?(view, "#admin-dashboard")
      assert has_element?(view, "div", "Retention Runs")

      render_click(element(view, ~s([phx-value-key="retention_runs"])))

      assert has_element?(view, "#platform-detail-panel")
      assert has_element?(view, "#platform-detail-panel", to_string(status))

      if count > 0 do
        assert has_element?(view, "#platform-detail-panel", "check_ins_anonymized")
      end
    end
  end

  @spec create_user(String.t()) :: User.t()
  defp create_user(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "retention_admin_#{tag}_#{n}@example.com",
          display_name: "Retention Admin #{tag} #{n}",
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
end
