defmodule Platser.Activity.Entry.Changes.CheckIn do
  use Ash.Resource.Change

  @impl Ash.Resource.Change
  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
          Ash.Changeset.t()
  def change(changeset, _opts, context) do
    actor = context.actor

    changeset
    |> Ash.Changeset.force_change_attribute(:action, :checked_in)
    |> Ash.Changeset.force_change_attribute(:subject_type, "user")
    |> Ash.Changeset.force_change_attribute(:subject_id, actor.id)
  end
end
