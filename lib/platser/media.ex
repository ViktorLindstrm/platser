defmodule Platser.Media do
  use Ash.Domain,
    otp_app: :platser

  resources do
    resource Platser.Media.Attachment do
      define :list_attachments_for_poi, action: :list_by_poi, args: [:poi_id]
      define :list_attachments_for_geofence, action: :list_by_geofence, args: [:geofence_id]
      define :get_attachment_by_path, action: :get_by_path, args: [:path]
      define :create_attachment, action: :create
      define :create_geofence_attachment, action: :create_for_geofence
      define :delete_attachment, action: :destroy
    end
  end
end
