defmodule Platser.Events do
  use Ash.Domain,
    otp_app: :platser

  resources do
    resource Platser.Events.Event
    resource Platser.Events.Membership
  end
end
