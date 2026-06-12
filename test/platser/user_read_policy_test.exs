defmodule Platser.UserReadPolicyTest do
  use Platser.DataCase, async: false

  alias Platser.Accounts.User
  alias Platser.Events
  alias Platser.Events.Event
  alias Platser.Events.Membership

  test "a user can read their own record including email" do
    user = create_user("self")

    assert {:ok, read_user} = Ash.get(User, user.id, actor: user)
    assert read_user.id == user.id
    assert read_user.display_name == user.display_name
    assert read_user.email == user.email
  end

  test "same-event members can read display identity but not email" do
    admin = create_user("same_event_admin")
    member = create_user("same_event_member")
    event = create_event(admin)
    _membership = join_event!(member, event)

    assert {:ok, read_user} = Ash.get(User, member.id, actor: admin)
    assert read_user.id == member.id
    assert read_user.display_name == member.display_name
    assert %Ash.ForbiddenField{field: :email} = read_user.email
  end

  test "unrelated authenticated users cannot read arbitrary users" do
    actor = create_user("unrelated_actor")
    target = create_user("unrelated_target")

    assert {:error, _error} = Ash.get(User, target.id, actor: actor)
  end

  test "unrelated authenticated users cannot discover arbitrary user emails through list reads" do
    actor = create_user("list_actor")
    target = create_user("list_target")

    assert {:ok, users} = Ash.read(User, actor: actor)

    assert Enum.any?(users, &(&1.id == actor.id))
    refute Enum.any?(users, &(&1.id == target.id))
  end

  test "superusers can read arbitrary users including email" do
    superuser = create_user("superuser")
    target = create_user("superuser_target")
    superuser = set_superuser!(superuser)

    assert {:ok, read_user} = Ash.get(User, target.id, actor: superuser)
    assert read_user.id == target.id
    assert read_user.email == target.email
  end

  @spec create_user(String.t()) :: User.t()
  defp create_user(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "user_read_#{tag}_#{n}@example.com",
          display_name: "User Read #{tag} #{n}",
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end

  @spec create_event(User.t()) :: Event.t()
  defp create_event(user) do
    {:ok, event} =
      Events.create_event(
        %{
          name: "User Read Event",
          description: "User read policy test event",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: user
      )

    event
  end

  @spec join_event!(User.t(), Event.t()) :: Membership.t()
  defp join_event!(user, event) do
    {:ok, membership} = Events.join_event(event.join_code, actor: user)
    membership
  end

  @spec set_superuser!(User.t()) :: User.t()
  defp set_superuser!(user) do
    {:ok, superuser} =
      Ash.update(user, %{superuser: true}, action: :set_superuser, authorize?: false)

    superuser
  end
end
