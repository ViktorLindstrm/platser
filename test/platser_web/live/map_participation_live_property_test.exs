defmodule PlatserWeb.MapParticipationLivePropertyTest do
  use PlatserWeb.ConnCase, async: false
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias Platser.Accounts.User
  alias Platser.Activity
  alias Platser.EventPresence
  alias Platser.Events
  alias Platser.Events.Event
  alias Platser.Map, as: PlatserMap

  describe "map participation controls" do
    property "member comment controls and submitted events follow comment settings" do
      check all(
              comments_enabled? <- StreamData.boolean(),
              tag <- StreamData.integer(1..1_000_000),
              max_runs: 6
            ) do
        owner = create_signed_in_user("comment_owner_#{tag}")
        member = create_signed_in_user("comment_member_#{tag}")
        event = create_event(owner, "Comment Live #{tag}")
        {:ok, _membership} = Events.join_event(event.join_code, actor: member)
        event = update_settings!(event, owner, %{allow_participant_comments: comments_enabled?})
        poi = create_published_poi(owner, event)

        conn = sign_in_conn(build_conn(), member)
        {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")
        render_hook(view, "inspect_map_object", %{kind: "poi", id: poi.id})

        if comments_enabled? do
          assert has_element?(view, "#map-item-comment-form")

          render_submit(element(view, "#map-item-comment-form"), %{
            "comment" => %{"body" => "Setting-controlled member note"}
          })

          assert comment_count(event, member) == 1
        else
          refute has_element?(view, "#map-item-comment-form")
          assert render(view) =~ "Comments are disabled for members right now"
          assert comment_count(event, member) == 0
        end
      end
    end

    property "member check-in events are accepted or rejected without unintended rows" do
      check all(
              check_ins_enabled? <- StreamData.boolean(),
              tag <- StreamData.integer(1..1_000_000),
              max_runs: 6
            ) do
        owner = create_signed_in_user("checkin_owner_#{tag}")
        member = create_signed_in_user("checkin_member_#{tag}")
        event = create_event(owner, "Check In Live #{tag}")
        {:ok, _membership} = Events.join_event(event.join_code, actor: member)
        event = update_settings!(event, owner, %{allow_participant_check_ins: check_ins_enabled?})

        conn = sign_in_conn(build_conn(), member)
        {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

        render_hook(view, "check_in", %{"lat" => 59.33, "lng" => 18.06})

        if check_ins_enabled? do
          assert check_in_count(event, member) == 1
        else
          assert render(view) =~ "Check-ins are disabled for members right now."
          assert check_in_count(event, member) == 0
        end
      end
    end

    property "member live location updates do not touch Presence when disabled" do
      check all(
              live_location_enabled? <- StreamData.boolean(),
              tag <- StreamData.integer(1..1_000_000),
              max_runs: 6
            ) do
        owner = create_signed_in_user("location_owner_#{tag}")
        member = create_signed_in_user("location_member_#{tag}")
        event = create_event(owner, "Location Live #{tag}")
        {:ok, _membership} = Events.join_event(event.join_code, actor: member)

        event =
          update_settings!(event, owner, %{
            allow_participant_live_location: live_location_enabled?
          })

        conn = sign_in_conn(build_conn(), member)
        {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

        render_click(element(view, "#share-location-btn"))
        render_hook(view, "location_update", %{"lat" => 59.33, "lng" => 18.06})

        locations = EventPresence.list_locations(event.id)

        if live_location_enabled? do
          assert Map.has_key?(locations, member.id)
        else
          refute Map.has_key?(locations, member.id)
          assert render(view) =~ "Live location sharing is disabled for members right now."
        end
      end
    end
  end

  @spec comment_count(Event.t(), User.t()) :: non_neg_integer()
  defp comment_count(event, actor) do
    {:ok, entries} = Activity.list_entries_for_event_with_filter(event.id, actor, :comments)
    length(entries)
  end

  @spec check_in_count(Event.t(), User.t()) :: non_neg_integer()
  defp check_in_count(event, actor) do
    {:ok, entries} = Activity.list_check_ins_for_event(event.id, actor: actor)
    length(entries)
  end

  @spec create_published_poi(User.t(), Event.t()) :: Platser.Map.Poi.t()
  defp create_published_poi(owner, event) do
    {:ok, poi} =
      PlatserMap.create_poi(
        %{
          name: "Participation POI",
          description: "Participation test",
          category: :viewpoint,
          location: %Geo.Point{coordinates: {18.06, 59.33}, srid: 4326},
          event_id: event.id
        },
        actor: owner
      )

    {:ok, published} = PlatserMap.publish_poi(poi, actor: owner)
    published
  end

  @spec create_signed_in_user(String.t()) :: User.t()
  defp create_signed_in_user(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "#{tag}_#{n}@example.com",
          display_name: "Map Participation User #{n}",
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
          description: "Map participation event",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: owner
      )

    event
  end

  @spec update_settings!(Event.t(), User.t(), map()) :: Event.t()
  defp update_settings!(event, actor, attrs) do
    {:ok, updated} = Events.update_event_settings(event, attrs, actor: actor)
    updated
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
