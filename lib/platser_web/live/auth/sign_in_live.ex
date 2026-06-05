defmodule PlatserWeb.AuthLive.SignInLive do
  @moduledoc """
  Custom sign-in page wrapper that renders the centered card layout.
  """

  use PlatserWeb, :live_view

  alias AshAuthentication.Phoenix.Components

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, session, socket) do
    overrides =
      Map.get(session, "overrides", [
        PlatserWeb.AuthOverrides,
        AshAuthentication.Phoenix.Overrides.Default
      ])

    socket =
      socket
      |> assign(overrides: overrides)
      |> assign_new(:otp_app, fn -> nil end)
      |> assign(:path, Map.get(session, "path", "/"))
      |> assign(:reset_path, Map.get(session, "reset_path"))
      |> assign(:register_path, Map.get(session, "register_path"))
      |> assign(:current_tenant, Map.get(session, "tenant"))
      |> assign(:resources, Map.get(session, "resources"))
      |> assign(:context, Map.get(session, "context", %{}))
      |> assign(:auth_routes_prefix, Map.get(session, "auth_routes_prefix"))
      |> assign(:gettext_fn, Map.get(session, "gettext_fn"))

    {:ok, socket}
  end

  @impl true
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_params(_, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-base-200 px-4">
      <div class="w-full max-w-sm bg-base-100 rounded-2xl shadow-xl p-8">
        <div class="text-center mb-6">
          <span class="text-2xl font-bold text-base-content">Platser</span>
          <p class="text-sm text-base-content/50 mt-1">Sign in to your account</p>
        </div>
        <.live_component
          module={Components.SignIn}
          id="sign-in-form"
          otp_app={@otp_app}
          live_action={@live_action}
          path={@path}
          auth_routes_prefix={@auth_routes_prefix}
          resources={@resources}
          reset_path={@reset_path}
          register_path={@register_path}
          overrides={@overrides}
          current_tenant={@current_tenant}
          context={@context}
          gettext_fn={@gettext_fn}
        />
      </div>
    </div>
    """
  end
end
