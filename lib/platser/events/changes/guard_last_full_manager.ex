defmodule Platser.Events.Changes.GuardLastFullManager do
  @full_manager_roles Platser.Events.MapAccess.roles_for_capability(:manage_members)

  use Ash.Resource.Change

  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
          Ash.Changeset.t()
  @impl true
  def change(changeset, _opts, _context) do
    membership = changeset.data
    full_manager_count = count_full_managers(membership.event_id)

    changeset =
      case Ash.Changeset.fetch_change(changeset, :role) do
        {:ok, role} ->
          guard_guest_manager_promotion(changeset, membership.user_id, role)

        :error ->
          changeset
      end

    cond do
      full_manager_count <= 1 and Platser.Events.MapAccess.full_manager?(membership.role) ->
        case Ash.Changeset.fetch_change(changeset, :role) do
          {:ok, role} ->
            if Platser.Events.MapAccess.full_manager?(role) do
              changeset
            else
              Ash.Changeset.add_error(
                changeset,
                field: :role,
                message: "Cannot demote the last map manager from an event."
              )
            end

          :error ->
            Ash.Changeset.add_error(
              changeset,
              field: :id,
              message: "Cannot remove the last map manager from an event."
            )
        end

      true ->
        changeset
    end
  end

  @spec count_full_managers(Ecto.UUID.t()) :: non_neg_integer()
  defp count_full_managers(event_id) do
    Platser.Events.Membership
    |> Ash.Query.filter(event_id == ^event_id and role in ^@full_manager_roles)
    |> Ash.count(authorize?: false)
    |> case do
      {:ok, count} -> count
      {:error, _} -> 0
    end
  end

  @spec guard_guest_manager_promotion(Ash.Changeset.t(), Ecto.UUID.t(), term()) ::
          Ash.Changeset.t()
  defp guard_guest_manager_promotion(changeset, user_id, role) do
    if Platser.Events.MapAccess.manager_role?(role) and guest_user?(user_id) do
      Ash.Changeset.add_error(
        changeset,
        field: :role,
        message: "Guest users cannot be promoted to map manager roles."
      )
    else
      changeset
    end
  end

  @spec guest_user?(Ecto.UUID.t()) :: boolean()
  defp guest_user?(user_id) do
    case Ash.get(Platser.Accounts.User, user_id, authorize?: false) do
      {:ok, %{is_guest: true}} -> true
      _ -> false
    end
  end
end
