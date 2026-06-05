defmodule Platser.Events.Changes.GuardLastAdmin do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    membership = changeset.data
    admin_count = count_admins(membership.event_id)

    cond do
      admin_count <= 1 and membership.role == :admin ->
        case Ash.Changeset.fetch_change(changeset, :role) do
          {:ok, :member} ->
            Ash.Changeset.add_error(
              changeset,
              field: :role,
              message: "Cannot demote the last admin from an event."
            )

          :error ->
            Ash.Changeset.add_error(
              changeset,
              field: :id,
              message: "Cannot remove the last admin from an event."
            )
        end

      true ->
        changeset
    end
  end

  @spec count_admins(Ecto.UUID.t()) :: integer()
  defp count_admins(event_id) do
    Platser.Events.Membership
    |> Ash.Query.filter(event_id: event_id, role: :admin)
    |> Ash.count(authorize?: false)
    |> case do
      {:ok, count} -> count
      {:error, _} -> 0
    end
  end
end
