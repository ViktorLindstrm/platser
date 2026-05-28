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

    sign_in_route register_path: "/register", reset_path: "/reset", auth_routes_prefix: "/auth"
    reset_route auth_routes_prefix: "/auth"
    sign_out_route AuthController
    auth_routes AuthController, Platser.Accounts.User, path: "/auth"
  end

  live_session :authenticated,
    on_mount: [
      {AshAuthentication.Phoenix.LiveSession, :default},
      {PlatserWeb.LiveUserAuth, :live_user_required}
    ] do
    scope "/", PlatserWeb do
      pipe_through :browser

      live "/join/:code", Events.JoinLive
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
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
