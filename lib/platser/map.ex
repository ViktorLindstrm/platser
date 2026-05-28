defmodule Platser.Map do
  use Ash.Domain,
    otp_app: :platser

  resources do
    resource Platser.Map.Poi
    resource Platser.Map.Geofence
  end
end
