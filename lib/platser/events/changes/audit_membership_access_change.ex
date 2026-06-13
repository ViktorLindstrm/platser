defmodule Platser.Events.Changes.AuditMembershipAccessChange do
  @moduledoc """
  Records manager-only audit rows for membership access changes.
  """

  use Ash.Resource.Change

  alias Platser.Events.MapAccess
  alias Platser.Events.Membership

  @type action :: :member_removed | :permission_changed

  @impl Ash.Resource.Change
  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
          Ash.Changeset.t()
  def change(changeset, opts, context) do
    actor = context.actor
    action = Keyword.fetch!(opts, :action)
    before_membership = changeset.data
    new_role = changed_role(changeset)

    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, membership} ->
          record(action, before_membership, membership, new_role, actor)
          {:ok, membership}

        :ok ->
          record(action, before_membership, before_membership, new_role, actor)
          :ok

        error ->
          error
      end
    end)
  end

  @spec changed_role(Ash.Changeset.t()) :: atom() | nil
  defp changed_role(changeset) do
    case Ash.Changeset.fetch_change(changeset, :role) do
      {:ok, role} -> role
      :error -> nil
    end
  end

  @spec record(
          action(),
          Membership.t(),
          Membership.t(),
          atom() | nil,
          Platser.Accounts.User.t() | nil
        ) ::
          :ok
  defp record(:member_removed, before_membership, _membership, _new_role, actor) do
    create_entry(%{
      action: :member_removed,
      event_id: before_membership.event_id,
      actor_id: actor_id(actor),
      target_user_id: before_membership.user_id,
      old_value: role_value(before_membership.role),
      new_value: nil,
      message: "Member removed from map.",
      metadata: %{"membership_id" => before_membership.id}
    })
  end

  defp record(:permission_changed, before_membership, membership, new_role, actor) do
    old_role = MapAccess.normalize(before_membership.role)
    changed_role = if new_role, do: MapAccess.normalize(new_role), else: old_role

    if old_role == changed_role do
      :ok
    else
      create_entry(%{
        action: :permission_changed,
        event_id: membership.event_id,
        actor_id: actor_id(actor),
        target_user_id: membership.user_id,
        old_value: Atom.to_string(old_role),
        new_value: Atom.to_string(changed_role),
        message: "Member permission level changed.",
        metadata: %{"membership_id" => membership.id}
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

  @spec role_value(MapAccess.compatible_role()) :: String.t()
  defp role_value(role), do: role |> MapAccess.normalize() |> Atom.to_string()
end
