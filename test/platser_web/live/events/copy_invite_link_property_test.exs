defmodule PlatserWeb.Events.CopyInviteLinkPropertyTest do
  use PlatserWeb.ConnCase, async: false
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias Platser.Accounts.User

  @moduledoc """
  StreamData property tests verifying that the copy invite link feature correctly
  constructs URLs and renders the button with the correct join code.
  """

  # ── Fixtures ─────────────────────────────────────────────────────────────────

  defp create_user(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "#{tag}_#{n}@example.com",
          display_name: String.capitalize("#{tag} #{n}"),
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    {:ok, signed_in_user} =
      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(User, :password),
        :sign_in,
        %{email: user.email, password: "password123"},
        authorize?: false
      )

    signed_in_user
  end

  defp sign_in_conn(conn, user) do
    signed_in_conn =
      conn
      |> put_private(:phoenix_endpoint, PlatserWeb.Endpoint)
      |> init_test_session(%{})
      |> PlatserWeb.AuthController.success(%{}, user, user.__metadata__.token)

    Phoenix.ConnTest.build_conn()
    |> put_private(:phoenix_endpoint, PlatserWeb.Endpoint)
    |> init_test_session(Map.get(signed_in_conn.private, :plug_session, %{}))
  end

  defp create_event_with_admin do
    admin = create_user("admin")

    {:ok, event} =
      Ash.create(
        Platser.Events.Event,
        %{
          name: "Copy Invite Test Event",
          description: "Testing copy invite link",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: admin
      )

    {admin, event}
  end

  # ── Tests ────────────────────────────────────────────────────────────────────

  describe "invite URL construction" do
    property "the invite URL always matches the pattern /join/[A-Z0-9]{6}$" do
      check all(_ <- StreamData.constant(:ok), max_runs: 20) do
        {_admin, event} = create_event_with_admin()

        assert Regex.match?(~r/^[A-Z0-9]{6}$/, event.join_code),
               "Join code #{event.join_code} should be 6 uppercase alphanumeric characters"

        url_suffix = "/join/#{event.join_code}"

        assert Regex.match?(~r|/join/[A-Z0-9]{6}$|, url_suffix),
               "URL #{url_suffix} should match pattern /join/[A-Z0-9]{6}$"
      end
    end
  end

  describe "dashboard render" do
    property "dashboard renders a copy invite link button with correct join code" do
      check all(_ <- StreamData.constant(:ok), max_runs: 5) do
        {admin, event} = create_event_with_admin()
        conn = sign_in_conn(build_conn(), admin)

        {:ok, view, _html} = live(conn, "/events/#{event.id}/dashboard")

        assert has_element?(view, "#copy-invite-link-btn"),
               "Copy invite link button should be present in the dashboard"

        assert has_element?(view, "#copy-invite-link-btn[data-join-code]"),
               "Button should have data-join-code attribute"
      end
    end

    property "dashboard button data-join-code matches the event join code" do
      check all(_ <- StreamData.constant(:ok), max_runs: 5) do
        {admin, event} = create_event_with_admin()
        conn = sign_in_conn(build_conn(), admin)

        {:ok, view, _html} = live(conn, "/events/#{event.id}/dashboard")

        html = render(view)

        assert html =~ "data-join-code=\"#{event.join_code}\"",
               "Button should have data-join-code=\"#{event.join_code}\""
      end
    end
  end

  # ── Helper function ──────────────────────────────────────────────────────────
end
