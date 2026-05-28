defmodule Platser.Types.Geometry do
  @moduledoc false

  use Ash.Type

  @type t :: Geo.geometry()

  @spec storage_type(term()) :: :geometry
  def storage_type(_), do: :geometry

  @spec cast_input(term(), keyword()) :: {:ok, t() | nil} | {:error, keyword()}
  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(value, _) do
    Geo.PostGIS.Geometry.cast(value)
  end

  @spec cast_stored(term(), keyword()) :: {:ok, t() | nil} | {:error, keyword()}
  def cast_stored(nil, _), do: {:ok, nil}

  def cast_stored(value, _) do
    Geo.PostGIS.Geometry.load(value)
  end

  @spec dump_to_native(term(), keyword()) :: {:ok, term() | nil} | {:error, keyword()}
  def dump_to_native(nil, _), do: {:ok, nil}

  def dump_to_native(value, _) do
    Geo.PostGIS.Geometry.dump(value)
  end
end
