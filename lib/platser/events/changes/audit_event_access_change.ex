defmodule Platser.Events.Changes.AuditEventAccessChange do
  @moduledoc """
  Records manager-only audit rows for event access-management changes.
  """

  use Ash.Resource.Change

  alias Platser.Events.Event

  @type action ::
          :join_code_regenerated | :join_code_invalidated | :participation_settings_changed

  @setting_fields [
    :allow_participant_comments,
    :allow_participant_check_ins,
    :allow_participant_live_location
  ]

  @impl Ash.Resource.Change
  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
          Ash.Changeset.t()
  def change(changeset, opts, context) do
    actor = context.actor
    action = Keyword.fetch!(opts, :action)
    before_event = changeset.data
    setting_changes = setting_changes(changeset, before_event)

    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, event} ->
          record(action, event, setting_changes, actor)
          {:ok, event}

        error ->
          error
      end
    end)
  end

  @spec setting_changes(Ash.Changeset.t(), Event.t()) :: map()
  defp setting_changes(changeset, before_event) do
    @setting_fields
    |> Enum.reduce(%{}, fn field, acc ->
      case Ash.Changeset.fetch_change(changeset, field) do
        {:ok, value} ->
          old_value = Map.fetch!(before_event, field)

          if value == old_value do
            acc
          else
            Map.put(acc, Atom.to_string(field), %{
              "old" => old_value,
              "new" => value
            })
          end

        _ ->
          acc
      end
    end)
  end

  @spec record(action(), Event.t(), map(), Platser.Accounts.User.t() | nil) :: :ok
  defp record(:join_code_regenerated, event, _setting_changes, actor) do
    create_entry(%{
      action: :join_code_regenerated,
      event_id: event.id,
      actor_id: actor_id(actor),
      old_value: "active",
      new_value: "regenerated",
      message: "Join code regenerated.",
      metadata: %{"changed_fields" => ["join_code", "join_code_expires_at"]}
    })
  end

  defp record(:join_code_invalidated, event, _setting_changes, actor) do
    create_entry(%{
      action: :join_code_invalidated,
      event_id: event.id,
      actor_id: actor_id(actor),
      old_value: "active",
      new_value: "invalidated",
      message: "Join code invalidated.",
      metadata: %{"changed_fields" => ["join_code_invalidated_at"]}
    })
  end

  defp record(:participation_settings_changed, event, setting_changes, actor) do
    if setting_changes == %{} do
      :ok
    else
      create_entry(%{
        action: :participation_settings_changed,
        event_id: event.id,
        actor_id: actor_id(actor),
        old_value: nil,
        new_value: nil,
        message: "Participation settings changed.",
        metadata: %{"settings" => setting_changes}
      })
    end
  end

  @spec create_entry(map()) :: :ok
  defp create_entry(%{actor_id: nil}), do: :ok

  defp create_entry(attrs) do
    case Platser.Events.create_manager_audit_entry(attrs, authorize?: false) do
      {:ok, _entry} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("Failed to create manager audit entry: #{inspect(reason)}")
        :ok
    end
  end

  @spec actor_id(Platser.Accounts.User.t() | nil) :: Ecto.UUID.t() | nil
  defp actor_id(nil), do: nil
  defp actor_id(actor), do: actor.id
end
