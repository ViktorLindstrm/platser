defmodule Platser.Events do
  use Ash.Domain,
    otp_app: :platser

  resources do
    resource Platser.Events.Event do
      define :create_event, action: :create
      define :list_events_for_user, action: :list_for_user
      define :get_event_by_join_code, action: :get_by_join_code, args: [:join_code]
      define :regenerate_event_join_code, action: :regenerate_join_code
    end

    resource Platser.Events.Membership do
      define :join_event, action: :join, args: [:join_code]
      define :list_memberships_for_event, action: :list_for_event, args: [:event_id]
    end
  end
end
