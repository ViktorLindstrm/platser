defmodule PlatserWeb.Events.JoinCodeLifecycleLivePropertyTest do
  use PlatserWeb.ConnCase, async: false
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias Platser.Accounts.User
  alias Platser.Events
  alias Platser.Events.Event
  alias PlatserWeb.JoinRateLimiter

  setup do
    JoinRateLimiter.reset_all()
    :ok
  end

  describe "join page lifecycle behavior" do
    property "accepted active codes let authenticated non-members join" do
      check all(tag <- StreamData.integer(1..1_000_000), max_runs: 5) do
        {_admin, event} = create_event("live_active_#{tag}", :active)
        user = create_signed_in_user("live_active_joiner_#{tag}")
        conn = sign_in_conn(build_conn(), user)

        {:ok, view, _html} = live(conn, ~p"/join/#{event.join_code}")

        assert has_element?(view, "#join-invite-panel")
        assert has_element?(view, "#join-btn")

        view
        |> element("#join-btn")
        |> render_click()

        assert has_element?(view, "#joined-panel")
      end
    end

    property "inactive codes render the invalid invite state" do
      check all(
              lifecycle <- StreamData.member_of([:expired, :rotated, :invalidated, :malformed]),
              tag <- StreamData.integer(1..1_000_000),
              max_runs: 12
            ) do
        {_admin, event} = create_event("live_#{lifecycle}_#{tag}", lifecycle)
        code = inactive_code(event, lifecycle)

        {:ok, view, _html} = live(build_conn(), ~p"/join/#{code}")

        assert has_element?(view, "#invalid-invite-panel")
        refute has_element?(view, "#guest-join-form")
        refute has_element?(view, "#join-btn")
      end
    end
  end

  describe "dashboard lifecycle controls" do
    property "admins can invalidate and regenerate the invite code from the dashboard" do
      check all(tag <- StreamData.integer(1..1_000_000), max_runs: 5) do
        {admin, event} = create_event("dashboard_lifecycle_#{tag}", :active)
        conn = sign_in_conn(build_conn(), admin)

        {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/dashboard")

        assert has_element?(view, "#copy-invite-link-btn")
        assert has_element?(view, "#invalidate-code-btn")

        view
        |> element("#invalidate-code-btn")
        |> render_click()

        refute has_element?(view, "#copy-invite-link-btn")
        refute has_element?(view, "#invalidate-code-btn")
        assert has_element?(view, "#regenerate-code-btn")

        view
        |> element("#regenerate-code-btn")
        |> render_click()

        assert has_element?(view, "#copy-invite-link-btn")
        assert has_element?(view, "#invalidate-code-btn")
      end
    end
  end

  @spec inactive_code(Event.t(), :expired | :rotated | :invalidated | :malformed) :: String.t()
  defp inactive_code(event, :expired), do: event.join_code
  defp inactive_code(event, :invalidated), do: event.join_code
  defp inactive_code(_event, :malformed), do: "missing-#{System.unique_integer([:positive])}"

  defp inactive_code(event, :rotated) do
    event.__metadata__.old_join_code
  end

  @spec create_event(String.t(), :active | :expired | :rotated | :invalidated | :malformed) ::
          {User.t(), Event.t()}
  defp create_event(tag, lifecycle) do
    admin = create_signed_in_user("#{tag}_admin")
    now = DateTime.utc_now(:second)

    attrs =
      case lifecycle do
        :expired ->
          %{
            starts_at: DateTime.add(now, -7_200, :second),
            ends_at: DateTime.add(now, -3_600, :second)
          }

        _ ->
          %{
            starts_at: DateTime.add(now, 3_600, :second),
            ends_at: DateTime.add(now, 7_200, :second)
          }
      end

    {:ok, event} =
      Ash.create(
        Event,
        Map.merge(attrs, %{
          name: "Lifecycle #{tag}",
          description: "Join-code lifecycle LiveView property test"
        }),
        actor: admin
      )

    event =
      case lifecycle do
        :invalidated ->
          {:ok, invalidated} = Events.invalidate_event_join_code(event, actor: admin)
          invalidated

        :rotated ->
          old_code = event.join_code
          {:ok, rotated} = Events.regenerate_event_join_code(event, actor: admin)
          %{rotated | __metadata__: Map.put(rotated.__metadata__, :old_join_code, old_code)}

        _ ->
          event
      end

    {admin, event}
  end

  @spec create_signed_in_user(String.t()) :: User.t()
  defp create_signed_in_user(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "#{tag}_#{n}@example.com",
          display_name: String.capitalize(String.replace(tag, "_", " ")),
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

  @spec sign_in_conn(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
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
end
