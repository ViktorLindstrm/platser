defmodule Platser.Accounts do
  use Ash.Domain,
    otp_app: :platser

  resources do
    resource Platser.Accounts.Token
    resource Platser.Accounts.User
  end
end
