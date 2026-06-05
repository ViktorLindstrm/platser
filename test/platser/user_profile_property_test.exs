defmodule Platser.UserProfilePropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  alias Platser.Accounts.User

  @moduledoc """
  StreamData property tests for the User profile domain.
  """

  # ── Fixtures ─────────────────────────────────────────────────────────────────

  @spec create_test_user(String.t()) :: {:ok, User.t()} | {:error, term()}
  defp create_test_user(display_name) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "profile_test_#{n}@example.com",
          display_name: display_name,
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    {:ok, user}
  end

  # ── Tests ────────────────────────────────────────────────────────────────────

  property "update_profile with any non-empty display_name always succeeds and persists" do
    check all(new_name <- StreamData.string(:printable, min_length: 1)) do
      {:ok, user} = create_test_user("Initial Name")

      {:ok, updated_user} =
        Ash.update(user, %{display_name: new_name},
          action: :update_profile,
          actor: user,
          authorize?: true
        )

      assert updated_user.display_name == new_name
    end
  end

  property "update_profile with empty display_name always returns validation error" do
    {:ok, user} = create_test_user("Initial Name")

    {:error, _changeset} =
      Ash.update(user, %{display_name: ""},
        action: :update_profile,
        actor: user,
        authorize?: true
      )
  end

  property "user can only update their own profile" do
    check all(new_name <- StreamData.string(:printable, min_length: 1)) do
      {:ok, user1} = create_test_user("User One")
      {:ok, user2} = create_test_user("User Two")

      # User1 tries to update User2's profile - should fail due to authorization
      result =
        Ash.update(user2, %{display_name: new_name},
          action: :update_profile,
          actor: user1,
          authorize?: true
        )

      assert match?({:error, _}, result)
    end
  end

  test "user can update their own display_name" do
    {:ok, user} = create_test_user("Original Name")

    {:ok, updated_user} =
      Ash.update(user, %{display_name: "Updated Name"},
        action: :update_profile,
        actor: user,
        authorize?: true
      )

    assert updated_user.display_name == "Updated Name"
  end

  test "update_profile action requires actor" do
    {:ok, user} = create_test_user("Initial Name")

    {:error, _} =
      Ash.update(user, %{display_name: "New Name"},
        action: :update_profile,
        actor: nil,
        authorize?: true
      )
  end

  test "display_name change is persisted across sessions" do
    {:ok, user} = create_test_user("Session Test User")
    new_display_name = "Updated Session Test User"

    {:ok, updated_user} =
      Ash.update(user, %{display_name: new_display_name},
        action: :update_profile,
        actor: user,
        authorize?: true
      )

    assert updated_user.display_name == new_display_name
  end
end
