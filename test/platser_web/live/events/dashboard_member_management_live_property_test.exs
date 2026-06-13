defmodule PlatserWeb.Events.DashboardMemberManagementLivePropertyTest do
  use PlatserWeb.ConnCase, async: false
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias Platser.Accounts
  alias Platser.Accounts.User
  alias Platser.Events
  alias Platser.Events.Event
  alias Platser.Events.MapAccess
  alias Platser.Events.Membership
  alias Platser.Map, as: PlatserMap
  alias Platser.Map.Poi

  describe "dashboard member management" do
    property "member rows expose identity, access, account, join, and contribution status" do
      check all(
              role <- StreamData.member_of(MapAccess.roles()),
              guest? <- StreamData.boolean(),
              tag <- StreamData.integer(1..1_000_000),
              max_runs: 9
            ) do
        manager = create_signed_in_user("member_manager_#{tag}")
        event = create_event(manager, "Members #{tag}")
        target = create_target_user(guest?, tag)
        membership = join_event!(event, target)
        membership = maybe_set_role(membership, role, manager, guest?)
        _poi = create_poi!(target, event, tag)

        conn = sign_in_conn(build_conn(), manager)
        {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/dashboard")

        assert has_element?(view, "#member-management-summary")
        assert has_element?(view, "#member-account-status-#{membership.id}")

        assert has_element?(
                 view,
                 "#member-access-level-#{membership.id}",
                 MapAccess.label(membership.role)
               )

        assert has_element?(view, "#member-contribution-status-#{membership.id}")
        assert has_element?(view, "#member-join-state-#{membership.id}")
        assert has_element?(view, "#member-participation-status-#{membership.id}")
        assert has_element?(view, "#member-controls-#{membership.id}")

        if target.is_guest do
          assert has_element?(view, "#promote-full-manager-#{membership.id}[disabled]")
          assert has_element?(view, "#promote-content-manager-#{membership.id}[disabled]")
        else
          refute has_element?(view, "#promote-full-manager-#{membership.id}[disabled]")
        end
      end
    end

    test "manager can promote, demote, and remove through stable controls", %{conn: conn} do
      manager = create_signed_in_user("controls_manager")
      event = create_event(manager, "Controls")
      target = create_signed_in_user("controls_target")
      membership = join_event!(event, target)

      conn = sign_in_conn(conn, manager)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/dashboard")

      view
      |> element("#promote-content-manager-#{membership.id}")
      |> render_click()

      assert has_element?(view, "#member-access-level-#{membership.id}", "Contributor manager")
      assert reloaded_membership!(event, target, manager).role == :content_manager

      view
      |> element("#demote-participant-#{membership.id}")
      |> render_click()

      assert has_element?(view, "#member-access-level-#{membership.id}", "Member")
      assert reloaded_membership!(event, target, manager).role == :participant

      view
      |> element("#remove-member-#{membership.id}")
      |> render_click()

      refute has_element?(view, "#member-controls-#{membership.id}")
      assert {:ok, nil} = own_membership(event, target, manager)
    end

    test "invalid submitted role transition is rejected without changing membership", %{
      conn: conn
    } do
      manager = create_signed_in_user("invalid_role_manager")
      event = create_event(manager, "Invalid Role")
      target = create_signed_in_user("invalid_role_target")
      membership = join_event!(event, target)

      conn = sign_in_conn(conn, manager)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/dashboard")

      render_click(view, "update_member_role", %{"id" => membership.id, "role" => "admin"})

      assert has_element?(view, "#member-access-level-#{membership.id}", "Member")
      assert reloaded_membership!(event, target, manager).role == :participant
    end
  end

  @spec create_signed_in_user(String.t()) :: User.t()
  defp create_signed_in_user(tag) do
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

    {:ok, signed_in_user} =
      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(User, :password),
        :sign_in,
        %{email: user.email, password: "password123"},
        authorize?: false
      )

    signed_in_user
  end

  @spec create_guest_user(String.t()) :: User.t()
  defp create_guest_user(display_name) do
    {:ok, guest} = Accounts.create_guest_user(display_name, authorize?: false)
    guest
  end

  @spec create_target_user(boolean(), integer()) :: User.t()
  defp create_target_user(true, tag), do: create_guest_user("Guest #{tag}")
  defp create_target_user(false, tag), do: create_signed_in_user("member_target_#{tag}")

  @spec create_event(User.t(), String.t()) :: Event.t()
  defp create_event(owner, name) do
    {:ok, event} =
      Events.create_event(
        %{
          name: name,
          description: "Member management event",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: owner
      )

    event
  end

  @spec join_event!(Event.t(), User.t()) :: Membership.t()
  defp join_event!(event, user) do
    {:ok, membership} = Events.join_event(event.join_code, actor: user)
    membership
  end

  @spec maybe_set_role(Membership.t(), MapAccess.role(), User.t(), boolean()) :: Membership.t()
  defp maybe_set_role(membership, role, _manager, true) when role != :participant, do: membership
  defp maybe_set_role(membership, :participant, _manager, _guest?), do: membership

  defp maybe_set_role(membership, role, manager, _guest?) do
    {:ok, updated} = Events.update_member_role(membership, %{role: role}, actor: manager)
    updated
  end

  @spec create_poi!(User.t(), Event.t(), integer()) :: Poi.t()
  defp create_poi!(user, event, tag) do
    {:ok, poi} =
      PlatserMap.create_poi(
        %{
          name: "Member POI #{tag}",
          description: "Contribution",
          category: :viewpoint,
          color: "#3B82F6",
          location: %Geo.Point{coordinates: {18.0, 59.0}, srid: 4326},
          event_id: event.id
        },
        actor: user
      )

    poi
  end

  @spec reloaded_membership!(Event.t(), User.t(), User.t()) :: Membership.t()
  defp reloaded_membership!(event, user, actor) do
    {:ok, membership} = own_membership(event, user, actor)
    membership
  end

  @spec own_membership(Event.t(), User.t(), User.t()) :: {:ok, Membership.t()} | {:error, term()}
  defp own_membership(event, user, actor) do
    require Ash.Query

    Membership
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(event_id == ^event.id and user_id == ^user.id)
    |> Ash.read_one(actor: actor)
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
