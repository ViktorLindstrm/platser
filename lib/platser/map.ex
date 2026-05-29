defmodule Platser.Map do
  use Ash.Domain,
    otp_app: :platser

  resources do
    resource Platser.Map.Poi do
      define :list_pois_for_event, action: :list_by_event, args: [:event_id]
      define :delete_poi, action: :destroy
    end

    resource Platser.Map.Geofence do
      define :list_geofences_for_event, action: :list_by_event, args: [:event_id]
      define :delete_geofence, action: :destroy
    end
  end
end
