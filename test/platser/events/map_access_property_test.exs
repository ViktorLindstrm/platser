defmodule Platser.Events.MapAccessPropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  require Ash.Query

  alias Platser.Accounts
  alias Platser.Accounts.User
  alias Platser.Events
  alias Platser.Events.Event
  alias Platser.Events.MapAccess
  alias Platser.Events.Membership
  alias Platser.Map
  alias Platser.Map.Geofence
  alias Platser.Map.Poi

  describe "role normalization and capabilities" do
    property "legacy roles normalize to the new map-scoped vocabulary" do
      check all(role <- StreamData.member_of(MapAccess.compatible_roles())) do
        normalized = MapAccess.normalize(role)

        assert normalized in MapAccess.roles()
        refute normalized in [:admin, :member]
      end
    end

    property "full manager capabilities are a superset of content manager and participant" do
      check all(capability <- StreamData.member_of(capabilities())) do
        if MapAccess.can?(:participant, capability) do
          assert MapAccess.can?(:content_manager, capability)
        end

        if MapAccess.can?(:content_manager, capability) do
          assert MapAccess.can?(:full_manager, capability)
        end
      end
    end

    property "policy role lists are derived from the canonical capability table" do
      check all(capability <- StreamData.member_of(capabilities())) do
        expected_roles =
          MapAccess.compatible_roles()
          |> Enum.filter(&MapAccess.can?(&1, capability))
          |> Enum.sort()

        assert Enum.sort(MapAccess.roles_for_capability(capability)) == expected_roles
      end
    end
  end

  describe "membership defaults and compatibility" do
    property "created events and joins use the migrated persistent role names" do
      check all(tag <- StreamData.integer(1..1_000_000), max_runs: 8) do
        owner = create_user("owner_#{tag}")
        joiner = create_user("joiner_#{tag}")
        event = create_event(owner, "Defaults #{tag}")

        assert {:ok, owner_membership} = own_membership(event, owner, owner)
        assert owner_membership.role == :full_manager

        assert {:ok, joined} = Events.join_event(event.join_code, actor: joiner)
        assert joined.role == :participant
      end
    end

    property "legacy rows remain readable and normalize correctly during migration" do
      check all(
              legacy_role <- StreamData.member_of([:admin, :member]),
              tag <- StreamData.integer(1..1_000_000),
              max_runs: 8
            ) do
        owner = create_user("legacy_owner_#{tag}")
        user = create_user("legacy_user_#{tag}")
        event = create_event(owner, "Legacy #{tag}")

        insert_membership!(event, user, legacy_role)

        assert {:ok, membership} = own_membership(event, user, user)
        assert membership.role == legacy_role
        assert MapAccess.normalize(membership.role) in [:full_manager, :participant]
      end
    end
  end

  describe "manager promotion boundaries" do
    property "guest members cannot be promoted to manager roles" do
      check all(
              target_role <- StreamData.member_of([:full_manager, :content_manager]),
              tag <- StreamData.integer(1..1_000_000),
              max_runs: 6
            ) do
        owner = create_user("guest_manager_owner_#{tag}")
        event = create_event(owner, "Guest Manager #{tag}")
        guest = create_guest_user("Guest #{tag}")

        assert {:ok, _membership} = Events.join_event(event.join_code, actor: guest)
        assert {:ok, guest_membership} = own_membership(event, guest, guest)

        assert {:error, %Ash.Error.Invalid{}} =
                 Events.update_member_role(guest_membership, %{role: target_role}, actor: owner)
      end
    end

    property "site-wide superuser alone does not grant map membership or map powers" do
      check all(tag <- StreamData.integer(1..1_000_000), max_runs: 5) do
        owner = create_user("owner_superuser_separation_#{tag}")
        superuser = create_user("service_admin_#{tag}") |> set_superuser!()
        event = create_event(owner, "Private #{tag}")
        poi = create_private_poi(event, owner, tag)

        assert {:error, _error} = Ash.get(Event, event.id, actor: superuser)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Events.update_event_settings(
                   event,
                   %{allow_participant_comments: true},
                   actor: superuser
                 )

        assert {:error, _error} = Ash.get(Poi, poi.id, actor: superuser)
      end
    end

    property "only full manager roles can update event settings and member roles" do
      check all(
              role <- StreamData.member_of(MapAccess.compatible_roles()),
              tag <- StreamData.integer(1..1_000_000),
              max_runs: 12
            ) do
        owner = create_user("owner_settings_#{tag}")
        actor = create_user("actor_settings_#{tag}")
        target = create_user("target_settings_#{tag}")
        event = create_event(owner, "Settings Boundary #{tag}")

        insert_membership!(event, actor, role)
        assert {:ok, target_membership} = Events.join_event(event.join_code, actor: target)

        settings_result =
          Events.update_event_settings(
            event,
            %{allow_participant_comments: true},
            actor: actor
          )

        role_result =
          Events.update_member_role(target_membership, %{role: :content_manager}, actor: actor)

        if MapAccess.can?(role, :manage_event_settings) do
          assert {:ok, _event} = settings_result
        else
          assert {:error, %Ash.Error.Forbidden{}} = settings_result
        end

        if MapAccess.can?(role, :manage_members) do
          assert {:ok, _membership} = role_result
        else
          assert {:error, %Ash.Error.Forbidden{}} = role_result
        end
      end
    end

    property "map-item capability controls private read, publish, update, and delete" do
      check all(
              role <- StreamData.member_of(MapAccess.compatible_roles()),
              resource <- StreamData.member_of([:poi, :geofence]),
              action <- StreamData.member_of([:read_private, :publish, :update_metadata, :delete]),
              tag <- StreamData.integer(1..1_000_000),
              max_runs: 20
            ) do
        owner = create_user("owner_map_item_#{tag}")
        actor = create_user("actor_map_item_#{tag}")
        event = create_event(owner, "Map Item Boundary #{tag}")
        insert_membership!(event, actor, role)

        item = create_private_map_item(resource, event, owner, tag)
        result = run_map_item_action(action, resource, item, actor, tag)

        if MapAccess.can?(role, :manage_any_map_item) do
          assert successful_map_item_result?(result)
        else
          refute successful_map_item_result?(result)
        end
      end
    end
  end

  @spec capabilities() :: [MapAccess.capability()]
  defp capabilities do
    [
      :read_event,
      :read_public_map_items,
      :read_private_map_items,
      :create_map_items,
      :publish_own_map_items,
      :manage_any_map_item,
      :manage_event_settings,
      :manage_members,
      :manage_join_code,
      :manage_permissions,
      :view_manager_audit
    ]
  end

  @spec create_user(String.t()) :: User.t()
  defp create_user(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "#{tag}_#{n}@example.com",
          display_name: "User #{tag} #{n}",
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end

  @spec create_guest_user(String.t()) :: User.t()
  defp create_guest_user(display_name) do
    {:ok, guest} = Accounts.create_guest_user(display_name, authorize?: false)
    guest
  end

  @spec create_event(User.t(), String.t()) :: Event.t()
  defp create_event(owner, name) do
    {:ok, event} =
      Events.create_event(
        %{
          name: name,
          description: "Private event",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: owner
      )

    event
  end

  @spec own_membership(Event.t(), User.t(), User.t()) :: {:ok, Membership.t()} | {:error, term()}
  defp own_membership(event, user, actor) do
    Membership
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(event_id == ^event.id and user_id == ^user.id)
    |> Ash.read_one(actor: actor)
  end

  @spec insert_membership!(Event.t(), User.t(), MapAccess.compatible_role()) :: :ok
  defp insert_membership!(event, user, role) do
    event_uuid = Ecto.UUID.dump!(event.id)
    user_uuid = Ecto.UUID.dump!(user.id)

    {:ok, _result} =
      Ecto.Adapters.SQL.query(
        Platser.Repo,
        """
        INSERT INTO memberships (id, event_id, user_id, role, joined_at)
        VALUES (gen_random_uuid(), $1, $2, $3, now())
        """,
        [event_uuid, user_uuid, Atom.to_string(role)]
      )

    :ok
  end

  @spec set_superuser!(User.t()) :: User.t()
  defp set_superuser!(user) do
    {:ok, superuser} =
      Ash.update(user, %{superuser: true}, action: :set_superuser, authorize?: false)

    superuser
  end

  @spec create_private_poi(Event.t(), User.t(), integer()) :: Poi.t()
  defp create_private_poi(event, owner, tag) do
    {:ok, poi} =
      Ash.create(
        Poi,
        %{
          event_id: event.id,
          name: "Private POI #{tag}",
          description: "Private",
          category: :other,
          color: "#3B82F6",
          location: %Geo.Point{coordinates: {18.0, 59.0}, srid: 4326}
        },
        actor: owner
      )

    poi
  end

  @spec create_private_map_item(:poi | :geofence, Event.t(), User.t(), integer()) ::
          Poi.t() | Geofence.t()
  defp create_private_map_item(:poi, event, owner, tag), do: create_private_poi(event, owner, tag)

  defp create_private_map_item(:geofence, event, owner, tag) do
    {:ok, geofence} =
      Map.create_geofence(
        %{
          event_id: event.id,
          name: "Private Geofence #{tag}",
          description: "Private",
          purpose: :meeting_zone,
          color: "#22C55E",
          geometry: %Geo.Polygon{
            coordinates: [
              [
                {18.0, 59.0},
                {18.01, 59.0},
                {18.01, 59.01},
                {18.0, 59.0}
              ]
            ],
            srid: 4326
          }
        },
        actor: owner
      )

    geofence
  end

  @spec run_map_item_action(
          :read_private | :publish | :update_metadata | :delete,
          :poi | :geofence,
          Poi.t() | Geofence.t(),
          User.t(),
          integer()
        ) :: :ok | {:ok, Poi.t() | Geofence.t()} | {:error, term()}
  defp run_map_item_action(:read_private, _resource, item, actor, _tag) do
    Ash.get(item.__struct__, item.id, actor: actor)
  end

  defp run_map_item_action(:publish, :poi, item, actor, _tag) do
    Map.publish_poi(item, actor: actor)
  end

  defp run_map_item_action(:publish, :geofence, item, actor, _tag) do
    Map.publish_geofence(item, actor: actor)
  end

  defp run_map_item_action(:update_metadata, :poi, item, actor, tag) do
    Map.update_poi_metadata(item, %{name: "Updated POI #{tag}"}, actor: actor)
  end

  defp run_map_item_action(:update_metadata, :geofence, item, actor, tag) do
    Map.update_geofence_metadata(item, %{name: "Updated Geofence #{tag}"}, actor: actor)
  end

  defp run_map_item_action(:delete, :poi, item, actor, _tag) do
    Map.delete_poi(item, actor: actor)
  end

  defp run_map_item_action(:delete, :geofence, item, actor, _tag) do
    Map.delete_geofence(item, actor: actor)
  end

  @spec successful_map_item_result?(term()) :: boolean()
  defp successful_map_item_result?(:ok), do: true
  defp successful_map_item_result?({:ok, %Poi{}}), do: true
  defp successful_map_item_result?({:ok, %Geofence{}}), do: true
  defp successful_map_item_result?(_result), do: false
end
