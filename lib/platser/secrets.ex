defmodule Platser.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        Platser.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:platser, :token_signing_secret)
  end
end
