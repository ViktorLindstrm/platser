defmodule Platser.Media do
  use Ash.Domain,
    otp_app: :platser

  resources do
    resource Platser.Media.Attachment do
      define :list_attachments_for_poi, action: :list_by_poi, args: [:poi_id]
      define :create_attachment, action: :create
      define :delete_attachment, action: :destroy
    end
  end
end
