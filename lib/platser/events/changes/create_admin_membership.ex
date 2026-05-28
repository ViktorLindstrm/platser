defmodule Platser.Events.Changes.CreateAdminMembership do
  @moduledoc """
  After-action hook that creates an admin Membership for the event creator.

  Runs inside the same transaction as the event create, so a membership
  failure rolls back the entire event creation.
  """
  use Ash.Resource.Change

  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
          Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, event ->
      result =
        Platser.Events.Membership
        |> Ash.Changeset.for_create(:create_admin, %{
          event_id: event.id,
          user_id: event.creator_id
        })
        |> Ash.create(authorize?: false)

      case result do
        {:ok, _membership} -> {:ok, event}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
