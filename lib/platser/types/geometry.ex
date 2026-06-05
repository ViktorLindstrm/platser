defmodule Platser.Types.Geometry do
  @moduledoc false

  use Ash.Type

  @type t :: Geo.geometry()

  @spec storage_type(term()) :: :geometry
  def storage_type(_), do: :geometry

  @spec cast_input(term(), keyword()) :: {:ok, t() | nil} | {:error, keyword()}
  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(%{__struct__: _} = value, _) do
    Geo.PostGIS.Geometry.cast(value)
  end

  def cast_input(value, _) when is_map(value) do
    case Geo.JSON.decode(value) do
      {:ok, geo} -> {:ok, geo}
      {:error, reason} -> {:error, message: inspect(reason)}
    end
  end

  def cast_input(value, _) do
    Geo.PostGIS.Geometry.cast(value)
  end

  @spec cast_stored(term(), keyword()) :: {:ok, t() | nil} | {:error, keyword()}
  def cast_stored(nil, _), do: {:ok, nil}

  def cast_stored(%{__struct__: _} = value, _) do
    Geo.PostGIS.Geometry.load(value)
  end

  def cast_stored(value, _) when is_map(value) do
    case Geo.JSON.decode(value) do
      {:ok, geo} -> {:ok, geo}
      {:error, _} -> Geo.PostGIS.Geometry.load(value)
    end
  end

  def cast_stored(value, _) do
    Geo.PostGIS.Geometry.load(value)
  end

  @spec dump_to_native(term(), keyword()) :: {:ok, term() | nil} | {:error, keyword()}
  def dump_to_native(nil, _), do: {:ok, nil}

  def dump_to_native(value, _) do
    Geo.PostGIS.Geometry.dump(value)
  end
end

# Elixir 1.18+ ships a built-in JSON module, so the `geo` hex package only
# implements JSON.Encoder (not Jason.Encoder). Ash internally uses Jason for
# serialisation, so we provide the implementation here.
defimpl Jason.Encoder,
  for: [
    Geo.Point,
    Geo.PointZ,
    Geo.LineString,
    Geo.LineStringZ,
    Geo.Polygon,
    Geo.PolygonZ,
    Geo.MultiPoint,
    Geo.MultiPointZ,
    Geo.MultiLineString,
    Geo.MultiLineStringZ,
    Geo.MultiPolygon,
    Geo.MultiPolygonZ,
    Geo.GeometryCollection
  ] do
  def encode(value, opts) do
    Jason.Encode.map(Geo.JSON.encode!(value), opts)
  end
end
