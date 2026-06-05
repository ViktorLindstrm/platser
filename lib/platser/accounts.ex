defmodule Platser.Accounts do
  use Ash.Domain,
    otp_app: :platser

  resources do
    resource Platser.Accounts.Token

    resource Platser.Accounts.User do
      define :create_guest_user, action: :create_guest, args: [:display_name]
      define :upgrade_guest_user, action: :upgrade_to_registered
    end
  end
end
