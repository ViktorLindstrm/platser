defmodule Platser.Events.Changes.GenerateJoinCode do
  @moduledoc """
  Generates a unique 6-character uppercase alphanumeric join code and sets it on the changeset.
  """
  use Ash.Resource.Change

  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
          Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    expires_at = join_code_expires_at(changeset)

    current_code =
      Ash.Changeset.get_attribute(changeset, :join_code) || Map.get(changeset.data, :join_code)

    changeset
    |> Ash.Changeset.force_change_attribute(:join_code, generate_replacement_code(current_code))
    |> Ash.Changeset.force_change_attribute(:join_code_expires_at, expires_at)
    |> Ash.Changeset.force_change_attribute(:join_code_rotated_at, DateTime.utc_now(:second))
    |> Ash.Changeset.force_change_attribute(:join_code_invalidated_at, nil)
  end

  @spec generate_code() :: String.t()
  defp generate_code do
    :crypto.strong_rand_bytes(4)
    |> Base.encode32(case: :upper, padding: false)
    |> binary_part(0, 6)
  end

  @spec generate_replacement_code(String.t() | nil) :: String.t()
  defp generate_replacement_code(current_code) do
    code = generate_code()

    if code == current_code do
      generate_replacement_code(current_code)
    else
      code
    end
  end

  @spec join_code_expires_at(Ash.Changeset.t()) :: DateTime.t() | nil
  defp join_code_expires_at(changeset) do
    Ash.Changeset.get_attribute(changeset, :ends_at) || Map.get(changeset.data, :ends_at)
  end
end
