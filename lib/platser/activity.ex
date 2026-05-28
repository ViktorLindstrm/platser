defmodule Platser.Activity do
  use Ash.Domain,
    otp_app: :platser

  resources do
    resource Platser.Activity.Entry
  end
end
