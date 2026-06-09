defmodule Platser.Map.Search.Result do
  @moduledoc """
  Normalized map search result used by internal and external providers.
  """

  @type source :: :internal | :external
  @type kind :: :poi | :address | :place | :coordinate | :category
  @type provider :: nil | :nominatim
  @type bounds :: %{west: float(), south: float(), east: float(), north: float()}

  @type t :: %__MODULE__{
          id: String.t(),
          source: source(),
          source_label: String.t(),
          kind: kind(),
          kind_label: String.t(),
          title: String.t(),
          subtitle: String.t() | nil,
          location: Geo.Point.t(),
          bounds: bounds() | nil,
          category: atom() | String.t() | nil,
          address: String.t() | nil,
          distance_m: non_neg_integer() | nil,
          provider: provider()
        }

  @enforce_keys [:id, :source, :source_label, :kind, :kind_label, :title, :location]
  defstruct [
    :id,
    :source,
    :source_label,
    :kind,
    :kind_label,
    :title,
    :subtitle,
    :location,
    :bounds,
    :category,
    :address,
    :distance_m,
    :provider
  ]
end
