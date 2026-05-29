defmodule PlatserWeb.MapInspection do
  @moduledoc false

  alias Platser.Map.Geofence
  alias Platser.Map.Poi

  @type kind :: :poi | :geofence
  @type visibility :: :private | :public
  @type status :: :draft | :published
  @type action :: :focus | :edit | :publish | :delete

  @spec kind_label(kind()) :: String.t()
  def kind_label(:poi), do: "Point of interest"
  def kind_label(:geofence), do: "Geofence"

  @spec status_label(visibility()) :: String.t()
  def status_label(:private), do: "Draft"
  def status_label(:public), do: "Published"

  @spec visibility_label(visibility()) :: String.t()
  def visibility_label(:private), do: "Private"
  def visibility_label(:public), do: "Public"

  @spec status(visibility()) :: status()
  def status(:private), do: :draft
  def status(:public), do: :published

  @spec available_actions(visibility(), boolean()) :: [action()]
  def available_actions(visibility, can_manage?) do
    [:focus] ++ if(can_manage?, do: manage_actions(visibility), else: [])
  end

  @spec resource_kind(Poi.t() | Geofence.t()) :: kind()
  def resource_kind(%Poi{}), do: :poi
  def resource_kind(%Geofence{}), do: :geofence

  @spec resource_visibility(%{visibility: visibility()}) :: visibility()
  def resource_visibility(%{visibility: visibility}), do: visibility

  @spec resource_status(%{visibility: visibility()}) :: status()
  def resource_status(%{visibility: visibility}), do: status(visibility)

  @spec manage_actions(visibility()) :: [action()]
  defp manage_actions(:private), do: [:edit, :publish, :delete]
  defp manage_actions(:public), do: [:delete]
end
