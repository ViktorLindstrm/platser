defmodule PlatserWeb.Router do
  use PlatserWeb, :router
  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PlatserWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :load_from_bearer
    plug :set_actor, :user
  end

  scope "/", PlatserWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/join", PageController, :join_redirect

    sign_in_route(
      register_path: "/register",
      reset_path: "/reset",
      auth_routes_prefix: "/auth",
      live_view: PlatserWeb.AuthLive.SignInLive,
      overrides: [PlatserWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default]
    )

    reset_route auth_routes_prefix: "/auth"
    sign_out_route AuthController
    auth_routes AuthController, Platser.Accounts.User, path: "/auth"

    post "/guest-join/:code", GuestController, :guest_join
    post "/upgrade-account", GuestController, :upgrade_account
  end

  # Publicly accessible join page — works for unauthenticated AND authenticated users.
  # AshAuthentication.Phoenix.LiveSession must come first so current_user is populated
  # for already-authenticated visitors.
  live_session :public_join,
    on_mount: [
      {AshAuthentication.Phoenix.LiveSession, :default},
      {PlatserWeb.LiveUserAuth, :live_user_optional}
    ] do
    scope "/", PlatserWeb do
      pipe_through :browser

      live "/join/:code", Events.JoinLive
    end
  end

  live_session :authenticated,
    on_mount: [
      {AshAuthentication.Phoenix.LiveSession, :default},
      {PlatserWeb.LiveUserAuth, :live_user_required}
    ] do
    scope "/", PlatserWeb do
      pipe_through :browser

      live "/events", Events.IndexLive
      live "/events/new", Events.NewLive
      live "/events/:id/dashboard", Events.DashboardLive
      live "/events/:event_id/map", MapLive
      live "/profile", ProfileLive
      live "/upgrade", UpgradeLive
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", PlatserWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:platser, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PlatserWeb.Telemetry
      live "/simulator", PlatserWeb.Dev.SimulatorLive
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
