defmodule Platser.JoinCodeLifecyclePropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  alias Platser.Accounts.User
  alias Platser.Events
  alias Platser.Events.Event

  describe "join-code lifecycle domain behavior" do
    property "active join codes can be looked up and used to join" do
      check all(tag <- StreamData.integer(1..1_000_000), max_runs: 10) do
        {_admin, event} = create_event("active_#{tag}", :active)
        joiner = create_user("active_joiner_#{tag}")

        assert {:ok, %Event{id: event_id}} =
                 Events.get_event_by_join_code(event.join_code, authorize?: false)

        assert event_id == event.id
        assert {:ok, membership} = Events.join_event(event.join_code, actor: joiner)
        assert membership.event_id == event.id
        assert membership.user_id == joiner.id
      end
    end

    property "expired, rotated, invalidated, and malformed join codes cannot be used" do
      check all(
              lifecycle <- StreamData.member_of([:expired, :rotated, :invalidated, :malformed]),
              tag <- StreamData.integer(1..1_000_000),
              max_runs: 20
            ) do
        {_admin, event} = create_event("#{lifecycle}_#{tag}", lifecycle)
        joiner = create_user("#{lifecycle}_joiner_#{tag}")
        code = inactive_code(event, lifecycle)

        assert inactive_lookup?(code)
        assert {:error, _error} = Events.join_event(code, actor: joiner)
      end
    end

    property "regeneration replaces an invalidated code with a usable active code" do
      check all(tag <- StreamData.integer(1..1_000_000), max_runs: 10) do
        {admin, event} = create_event("reactivate_#{tag}", :invalidated)
        old_code = event.join_code
        joiner = create_user("reactivated_joiner_#{tag}")

        assert {:ok, updated_event} = Events.regenerate_event_join_code(event, actor: admin)
        assert is_nil(updated_event.join_code_invalidated_at)
        refute updated_event.join_code == old_code
        assert {:error, _error} = Events.join_event(old_code, actor: joiner)
        assert {:ok, membership} = Events.join_event(updated_event.join_code, actor: joiner)
        assert membership.event_id == event.id
      end
    end
  end

  @spec inactive_code(Event.t(), :expired | :rotated | :invalidated | :malformed) :: String.t()
  defp inactive_code(event, :expired), do: event.join_code
  defp inactive_code(event, :invalidated), do: event.join_code
  defp inactive_code(_event, :malformed), do: "bad!"

  defp inactive_code(event, :rotated) do
    event.__metadata__.old_join_code
  end

  @spec inactive_lookup?(String.t()) :: boolean()
  defp inactive_lookup?(code) do
    case Events.get_event_by_join_code(code, authorize?: false) do
      {:ok, nil} -> true
      {:error, %Ash.Error.Invalid{}} -> true
      _other -> false
    end
  end

  @spec create_event(String.t(), :active | :expired | :rotated | :invalidated | :malformed) ::
          {User.t(), Event.t()}
  defp create_event(tag, lifecycle) do
    admin = create_user("#{tag}_admin")
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
          description: "Join-code lifecycle property test"
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

  @spec create_user(String.t()) :: User.t()
  defp create_user(tag) do
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

    user
  end
end
