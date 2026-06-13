defmodule PlatserWeb.Events.ParticipationSettingsLivePropertyTest do
  use PlatserWeb.ConnCase, async: false
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias Platser.Accounts.User
  alias Platser.Events
  alias Platser.Events.Event
  alias Platser.Events.ParticipationSettings

  describe "dashboard participation settings" do
    property "map managers can toggle each persisted participant setting from the dashboard" do
      check all(
              setting <- StreamData.member_of(ParticipationSettings.settings()),
              value <- StreamData.boolean(),
              tag <- StreamData.integer(1..1_000_000),
              max_runs: 9
            ) do
        manager = create_signed_in_user("settings_manager_#{tag}")
        event = create_event(manager, "Settings #{tag}")
        conn = sign_in_conn(build_conn(), manager)

        {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/dashboard")

        {selector, phx_value} = setting_control(setting, value)
        assert has_element?(view, selector)

        view
        |> element(selector)
        |> render_click(phx_value)

        updated = Ash.get!(Event, event.id, actor: manager)
        assert setting_enabled?(updated, setting) == value
      end
    end

    property "invalid setting keys and values are rejected before domain updates" do
      check all(
              key <- invalid_setting_key_gen(),
              value <- invalid_bool_gen(),
              max_runs: 20
            ) do
        assert ParticipationSettings.parse_setting(key) == :error
        assert ParticipationSettings.parse_boolean(value) == :error
      end
    end
  end

  @spec invalid_setting_key_gen() :: StreamData.t(String.t())
  defp invalid_setting_key_gen do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 24)
    |> StreamData.filter(&(&1 not in ["comments", "check_ins", "live_location"]))
  end

  @spec invalid_bool_gen() :: StreamData.t(String.t())
  defp invalid_bool_gen do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 12)
    |> StreamData.filter(&(&1 not in ["true", "false"]))
  end

  @spec setting_control(ParticipationSettings.setting(), boolean()) ::
          {String.t(), %{String.t() => String.t()}}
  defp setting_control(:comments, value),
    do: {"#toggle-member-comments-btn", %{"allow_participant_comments" => to_string(value)}}

  defp setting_control(:check_ins, value),
    do: {"#toggle-member-check-ins-btn", %{"check_ins" => to_string(value)}}

  defp setting_control(:live_location, value),
    do: {"#toggle-member-live-location-btn", %{"live_location" => to_string(value)}}

  @spec setting_enabled?(Event.t(), ParticipationSettings.setting()) :: boolean()
  defp setting_enabled?(event, :comments), do: event.allow_participant_comments
  defp setting_enabled?(event, :check_ins), do: event.allow_participant_check_ins
  defp setting_enabled?(event, :live_location), do: event.allow_participant_live_location

  @spec create_signed_in_user(String.t()) :: User.t()
  defp create_signed_in_user(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "#{tag}_#{n}@example.com",
          display_name: "Settings User #{n}",
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

  @spec create_event(User.t(), String.t()) :: Event.t()
  defp create_event(owner, name) do
    {:ok, event} =
      Events.create_event(
        %{
          name: name,
          description: "Settings event",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: owner
      )

    event
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
