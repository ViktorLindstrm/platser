defmodule Platser.MapSearchTest do
  use Platser.DataCase, async: false

  alias Platser.Events
  alias Platser.Map, as: PlatserMap
  alias Platser.Map.Search
  alias Platser.Map.Search.Result

  describe "search_internal/4" do
    test "normalizes visible POI matches by name, description, and category" do
      user = create_user()
      event = create_event(user)

      poi =
        create_poi!(user, event, %{
          name: "North Camp",
          description: "Sheltered forest site",
          category: :camp,
          location: point(18.0, 59.0)
        })

      {:ok, [name_result]} = Search.search_internal(event.id, "north", user)
      assert_internal_result(name_result, poi, "Camp")

      {:ok, [description_result]} = Search.search_internal(event.id, "forest", user)
      assert_internal_result(description_result, poi, "Camp")

      {:ok, [category_result]} = Search.search_internal(event.id, "camp", user)
      assert_internal_result(category_result, poi, "Camp")
    end

    test "coordinate queries match nearby POIs and exclude distant POIs" do
      user = create_user()
      event = create_event(user)

      near =
        create_poi!(user, event, %{
          name: "Near marker",
          category: :viewpoint,
          location: point(18.0003, 59.0003)
        })

      _far =
        create_poi!(user, event, %{
          name: "Far marker",
          category: :viewpoint,
          location: point(18.5, 59.5)
        })

      {:ok, [result]} = Search.search_internal(event.id, "59.0000,18.0000", user)

      assert result.title == near.name
      assert result.distance_m in 0..1_000
      assert %Geo.Point{coordinates: {18.0003, 59.0003}, srid: 4326} = result.location
    end

    test "does not return POIs from another event" do
      user = create_user()
      current_event = create_event(user)
      other_event = create_event(user)

      current_poi =
        create_poi!(user, current_event, %{
          name: "Shared Camp",
          category: :camp,
          location: point(18.0, 59.0)
        })

      _other_poi =
        create_poi!(user, other_event, %{
          name: "Shared Camp",
          category: :camp,
          location: point(19.0, 60.0)
        })

      {:ok, results} = Search.search_internal(current_event.id, "shared", user)

      assert Enum.map(results, & &1.title) == [current_poi.name]
      assert Enum.map(results, & &1.id) == ["internal:poi:#{current_poi.id}"]
    end

    test "respects POI draft visibility for event members, creators, and admins" do
      admin = create_user()
      member = create_user()
      event = create_event(admin)
      join_event!(member, event)

      draft =
        create_poi!(admin, event, %{
          name: "Hidden Draft Camp",
          category: :camp,
          location: point(18.0, 59.0)
        })

      public =
        admin
        |> create_poi!(event, %{
          name: "Public Camp",
          category: :camp,
          location: point(18.1, 59.1)
        })
        |> publish_poi!(admin)

      member_draft =
        create_poi!(member, event, %{
          name: "Member Draft Camp",
          category: :camp,
          location: point(18.2, 59.2)
        })

      assert {:ok, member_results} = Search.search_internal(event.id, "camp", member)
      assert result_titles(member_results) == ["Member Draft Camp", "Public Camp"]

      assert {:ok, admin_results} = Search.search_internal(event.id, "camp", admin)

      assert result_titles(admin_results) == [
               "Hidden Draft Camp",
               "Member Draft Camp",
               "Public Camp"
             ]

      assert {:ok, creator_results} = Search.search_internal(event.id, "hidden", admin)
      assert result_titles(creator_results) == [draft.name]

      assert {:ok, public_results} = Search.search_internal(event.id, "public", member)
      assert result_titles(public_results) == [public.name]

      assert {:ok, member_draft_results} =
               Search.search_internal(event.id, "member draft", member)

      assert result_titles(member_draft_results) == [member_draft.name]
    end
  end

  describe "parse_coordinates/1" do
    test "stores latitude longitude input as longitude latitude WGS84 points" do
      assert {:ok, %Geo.Point{coordinates: {18.12, 59.32}, srid: 4326}} =
               Search.parse_coordinates("59.32,18.12")
    end

    test "rejects out-of-range and non-strict coordinate input" do
      assert :error = Search.parse_coordinates("91,18")
      assert :error = Search.parse_coordinates("59,181")
      assert :error = Search.parse_coordinates("59.0,18.0,extra")
      assert :error = Search.parse_coordinates("59.0 north,18.0 east")
    end
  end

  @spec create_user() :: Platser.Accounts.User.t()
  defp create_user do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        Platser.Accounts.User,
        %{
          email: "map_search_#{n}@example.com",
          display_name: "Map Search User #{n}",
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end

  @spec create_event(Platser.Accounts.User.t()) :: Platser.Events.Event.t()
  defp create_event(user) do
    {:ok, event} =
      Events.create_event(
        %{
          name: "Search Test Event",
          description: "Search test event",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: user
      )

    event
  end

  @spec join_event!(Platser.Accounts.User.t(), Platser.Events.Event.t()) ::
          Platser.Events.Membership.t()
  defp join_event!(user, event) do
    {:ok, membership} = Events.join_event(event.join_code, actor: user)
    membership
  end

  @spec create_poi!(Platser.Accounts.User.t(), Platser.Events.Event.t(), map()) ::
          Platser.Map.Poi.t()
  defp create_poi!(user, event, attrs) do
    {:ok, poi} =
      PlatserMap.create_poi(
        Map.merge(
          %{
            name: "Search POI",
            category: :other,
            location: point(18.0, 59.0),
            event_id: event.id
          },
          attrs
        ),
        actor: user
      )

    poi
  end

  @spec publish_poi!(Platser.Map.Poi.t(), Platser.Accounts.User.t()) :: Platser.Map.Poi.t()
  defp publish_poi!(poi, user) do
    {:ok, published} = PlatserMap.publish_poi(poi, actor: user)
    published
  end

  @spec point(float(), float()) :: Geo.Point.t()
  defp point(lng, lat), do: %Geo.Point{coordinates: {lng, lat}, srid: 4326}

  @spec assert_internal_result(Result.t(), Platser.Map.Poi.t(), String.t()) :: true
  defp assert_internal_result(result, poi, kind_label) do
    assert %Result{} = result
    assert result.id == "internal:poi:#{poi.id}"
    assert result.source == :internal
    assert result.source_label == "Event POI"
    assert result.kind == :poi
    assert result.kind_label == kind_label
    assert result.title == poi.name
    assert result.location == poi.location
  end

  @spec result_titles([Result.t()]) :: [String.t()]
  defp result_titles(results) do
    results
    |> Enum.map(& &1.title)
    |> Enum.sort()
  end
end
