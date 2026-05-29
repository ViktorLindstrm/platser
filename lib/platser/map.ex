defmodule Platser.Map do
  use Ash.Domain,
    otp_app: :platser

  resources do
    resource Platser.Map.Poi do
      define :list_pois_for_event, action: :list_by_event, args: [:event_id]
      define :create_poi, action: :create
      define :get_poi, action: :read, get_by: [:id]
      define :update_poi, action: :update
      define :update_poi_metadata, action: :update_metadata
      define :publish_poi, action: :publish
      define :delete_poi, action: :destroy
    end

    resource Platser.Map.Geofence do
      define :list_geofences_for_event, action: :list_by_event, args: [:event_id]
      define :create_geofence, action: :create
      define :get_geofence, action: :read, get_by: [:id]
      define :update_geofence, action: :update
      define :update_geofence_metadata, action: :update_metadata
      define :publish_geofence, action: :publish
      define :delete_geofence, action: :destroy
    end
  end
end
