defmodule Platser.Activity do
  use Ash.Domain,
    otp_app: :platser

  resources do
    resource Platser.Activity.Entry do
      define :list_entries_for_event, action: :list_by_event, args: [:event_id]
      define :create_entry, action: :create
    end
  end
end
