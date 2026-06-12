defmodule PlatserWeb.Plugs.JoinRateLimit do
  @moduledoc """
  Rejects excessive invite-code lookups before public join actions run.
  """

  import Plug.Conn

  alias PlatserWeb.JoinRateLimiter

  @type opts :: keyword()

  @spec init(opts()) :: opts()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), opts()) :: Plug.Conn.t()
  def call(%Plug.Conn{params: %{"code" => code}, remote_ip: remote_ip} = conn, _opts)
      when is_binary(code) do
    case JoinRateLimiter.allow?(remote_ip, code) do
      :allow ->
        conn

      :throttle ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(429, "Too many invite attempts. Please try again later.")
        |> halt()
    end
  end

  def call(conn, _opts), do: conn
end
