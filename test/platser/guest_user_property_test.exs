defmodule Platser.GuestUserPropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  alias Platser.Accounts
  alias Platser.Accounts.User
  alias Platser.Events

  @moduledoc """
  StreamData property tests for the temporary guest user feature (ADR-0026).

  Covers:
  - Guest user provisioning
  - Event creation denied for guests
  - Upgrade path: guest → registered user preserves user ID and memberships
  """

  # ── Fixtures ─────────────────────────────────────────────────────────────────

  @spec create_registered_user() :: User.t()
  defp create_registered_user do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "registered_#{n}@example.com",
          display_name: "Registered User #{n}",
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end

  @spec create_guest_user(String.t() | nil) :: User.t()
  defp create_guest_user(display_name \\ nil) do
    {:ok, guest} =
      Accounts.create_guest_user(display_name || "", authorize?: false)

    guest
  end

  @spec create_event(User.t()) :: Platser.Events.Event.t()
  defp create_event(admin) do
    {:ok, event} =
      Ash.create(
        Platser.Events.Event,
        %{
          name: "Test Event",
          description: "desc",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: admin
      )

    event
  end

  # ── Guest provisioning ───────────────────────────────────────────────────────

  describe "guest user provisioning" do
    property "creates a user with is_guest: true for any display_name" do
      check all(name <- StreamData.string(:printable, min_length: 0, max_length: 50)) do
        {:ok, guest} = Accounts.create_guest_user(name, authorize?: false)
        assert guest.is_guest == true
      end
    end

    property "generates a unique synthetic email for each guest" do
      check all(_ <- StreamData.constant(:ok), max_runs: 20) do
        {:ok, g1} = Accounts.create_guest_user("", authorize?: false)
        {:ok, g2} = Accounts.create_guest_user("", authorize?: false)
        refute g1.email == g2.email
        assert String.ends_with?(to_string(g1.email), "@platser.guest")
        assert String.ends_with?(to_string(g2.email), "@platser.guest")
      end
    end

    property "auto-generates a non-empty display_name when blank is provided" do
      check all(_ <- StreamData.constant(:ok), max_runs: 20) do
        {:ok, guest} = Accounts.create_guest_user("", authorize?: false)
        assert String.length(guest.display_name) > 0
      end
    end

    property "preserves a provided display_name (non-empty)" do
      check all(name <- StreamData.string(:printable, min_length: 1, max_length: 80)) do
        {:ok, guest} = Accounts.create_guest_user(name, authorize?: false)
        assert guest.display_name == name
      end
    end

    property "guest users have no hashed_password" do
      check all(_ <- StreamData.constant(:ok), max_runs: 10) do
        {:ok, guest} = Accounts.create_guest_user("", authorize?: false)
        assert is_nil(guest.hashed_password)
      end
    end
  end

  # ── Event creation guard ─────────────────────────────────────────────────────

  describe "event creation denied for guests" do
    property "guest users cannot create events" do
      check all(_ <- StreamData.constant(:ok), max_runs: 10) do
        guest = create_guest_user()

        result =
          Ash.create(
            Platser.Events.Event,
            %{
              name: "Guest Event",
              starts_at: DateTime.utc_now(),
              ends_at: DateTime.add(DateTime.utc_now(), 3600)
            },
            actor: guest,
            authorize?: true
          )

        assert match?({:error, _}, result),
               "Expected event creation to fail for guest users"
      end
    end

    property "registered users can always create events" do
      check all(_ <- StreamData.constant(:ok), max_runs: 10) do
        user = create_registered_user()

        result =
          Ash.create(
            Platser.Events.Event,
            %{
              name: "Registered Event",
              starts_at: DateTime.utc_now(),
              ends_at: DateTime.add(DateTime.utc_now(), 3600)
            },
            actor: user,
            authorize?: true
          )

        assert match?({:ok, _}, result),
               "Expected event creation to succeed for registered users"
      end
    end
  end

  # ── Guest joining events ─────────────────────────────────────────────────────

  describe "guest users can join events" do
    property "guest user can join an event via join code" do
      check all(_ <- StreamData.constant(:ok), max_runs: 10) do
        admin = create_registered_user()
        event = create_event(admin)
        guest = create_guest_user("Test Guest")

        assert {:ok, _membership} = Events.join_event(event.join_code, actor: guest)
      end
    end

    property "guest user membership is persisted and readable" do
      check all(_ <- StreamData.constant(:ok), max_runs: 10) do
        admin = create_registered_user()
        event = create_event(admin)
        guest = create_guest_user()

        {:ok, _} = Events.join_event(event.join_code, actor: guest)

        {:ok, memberships} = Events.list_memberships_for_event(event.id, actor: admin)
        guest_membership = Enum.find(memberships, &(&1.user_id == guest.id))

        assert guest_membership != nil
        assert guest_membership.role == :member
      end
    end
  end

  # ── Upgrade path ─────────────────────────────────────────────────────────────

  describe "upgrade guest to registered user" do
    property "upgrade preserves user ID" do
      check all(_ <- StreamData.constant(:ok), max_runs: 10) do
        guest = create_guest_user("Pre-Upgrade Guest")
        original_id = guest.id
        n = System.unique_integer([:positive])

        {:ok, upgraded} =
          Ash.update(
            guest,
            %{
              email: "upgraded_#{n}@example.com",
              password: "password123",
              password_confirmation: "password123"
            },
            action: :upgrade_to_registered,
            actor: guest,
            authorize?: true,
            context: %{strategy_name: :password}
          )

        assert upgraded.id == original_id
      end
    end

    property "upgrade sets is_guest to false" do
      check all(_ <- StreamData.constant(:ok), max_runs: 10) do
        guest = create_guest_user()
        n = System.unique_integer([:positive])

        {:ok, upgraded} =
          Ash.update(
            guest,
            %{
              email: "upgraded_#{n}@example.com",
              password: "password123",
              password_confirmation: "password123"
            },
            action: :upgrade_to_registered,
            actor: guest,
            authorize?: true,
            context: %{strategy_name: :password}
          )

        assert upgraded.is_guest == false
      end
    end

    property "upgrade preserves memberships (user_id unchanged)" do
      check all(_ <- StreamData.constant(:ok), max_runs: 10) do
        admin = create_registered_user()
        event = create_event(admin)
        guest = create_guest_user()
        {:ok, _} = Events.join_event(event.join_code, actor: guest)
        n = System.unique_integer([:positive])

        {:ok, upgraded} =
          Ash.update(
            guest,
            %{
              email: "upgraded_#{n}@example.com",
              password: "password123",
              password_confirmation: "password123"
            },
            action: :upgrade_to_registered,
            actor: guest,
            authorize?: true,
            context: %{strategy_name: :password}
          )

        {:ok, memberships} = Events.list_memberships_for_event(event.id, actor: admin)
        member = Enum.find(memberships, &(&1.user_id == upgraded.id))

        assert member != nil,
               "Membership should still exist after upgrade since user_id did not change"
      end
    end

    property "registered user cannot use upgrade_to_registered action" do
      check all(_ <- StreamData.constant(:ok), max_runs: 10) do
        user = create_registered_user()
        n = System.unique_integer([:positive])

        result =
          Ash.update(
            user,
            %{
              email: "hacker_#{n}@example.com",
              password: "newpassword123",
              password_confirmation: "newpassword123"
            },
            action: :upgrade_to_registered,
            actor: user,
            authorize?: true,
            context: %{strategy_name: :password}
          )

        assert match?({:error, _}, result),
               "Expected registered users to be blocked from upgrade_to_registered"
      end
    end

    property "upgrade with mismatched passwords always fails" do
      check all(_ <- StreamData.constant(:ok), max_runs: 10) do
        guest = create_guest_user()
        n = System.unique_integer([:positive])

        result =
          Ash.update(
            guest,
            %{
              email: "mismatch_#{n}@example.com",
              password: "password123",
              password_confirmation: "different_password"
            },
            action: :upgrade_to_registered,
            actor: guest,
            authorize?: true,
            context: %{strategy_name: :password}
          )

        assert match?({:error, _}, result)
      end
    end
  end
end
