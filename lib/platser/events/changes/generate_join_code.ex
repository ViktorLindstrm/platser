defmodule Platser.Events.Changes.GenerateJoinCode do
  @moduledoc """
  Generates a unique 6-character uppercase alphanumeric join code and sets it on the changeset.
  """
  use Ash.Resource.Change

  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
          Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    Ash.Changeset.force_change_attribute(changeset, :join_code, generate_code())
  end

  @spec generate_code() :: String.t()
  defp generate_code do
    :crypto.strong_rand_bytes(4)
    |> Base.encode32(case: :upper, padding: false)
    |> binary_part(0, 6)
  end
end
