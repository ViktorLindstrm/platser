defmodule Platser.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @start_gps_simulator Application.compile_env(:platser, :start_gps_simulator, false)

  @impl true
  def start(_type, _args) do
    children = [
      PlatserWeb.Telemetry,
      Platser.Repo,
      {DNSCluster, query: Application.get_env(:platser, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Platser.PubSub},
      Platser.EventPresence,
      Platser.Admin.ErrorBuffer,
      {Task.Supervisor, name: Platser.Privacy.ExportSupervisor},
      PlatserWeb.JoinRateLimiter,
      Platser.Map.Search.Geocoder.RateLimiter,
      # Start to serve requests, typically the last entry
      PlatserWeb.Endpoint,
      {AshAuthentication.Supervisor, [otp_app: :platser]}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    children =
      if @start_gps_simulator do
        children ++ [{Platser.Dev.GpsSimulator, []}]
      else
        children
      end

    opts = [strategy: :one_for_one, name: Platser.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PlatserWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
