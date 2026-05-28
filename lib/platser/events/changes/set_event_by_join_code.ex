defmodule Platser.Events.Changes.SetEventByJoinCode do
  @moduledoc """
  Resolves the event for a membership join action by looking up the event via join_code argument.
  Adds a changeset error if no matching event is found.
  """
  use Ash.Resource.Change

  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
          Ash.Changeset.t()
  def change(changeset, _opts, context) do
    join_code = Ash.Changeset.get_argument(changeset, :join_code)
    actor = Map.get(context, :actor)

    query =
      Ash.Query.for_read(Platser.Events.Event, :get_by_join_code, %{join_code: join_code})

    case Ash.read_one(query, actor: actor) do
      {:ok, nil} ->
        Ash.Changeset.add_error(changeset,
          field: :join_code,
          message: "is invalid or has expired"
        )

      {:ok, event} ->
        Ash.Changeset.force_change_attribute(changeset, :event_id, event.id)

      {:error, _} ->
        Ash.Changeset.add_error(changeset,
          field: :join_code,
          message: "is invalid or has expired"
        )
    end
  end
end
