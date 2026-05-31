defmodule PlatserWeb.AuthLive.SignInLive do
  @moduledoc """
  Custom sign-in page wrapper that provides three selectable visual layouts
  via the Tidewave variant system. The actual live authentication form is
  rendered in each variant; static previews are used in hidden variants
  to avoid Phoenix LiveView's duplicate live_component ID restriction.
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
    <div data-tw-container="Auth Layout">
      <%!-- Variant 1: Centered Card — full live form --%>
      <div
        data-tw-variant="Centered Card"
        class="min-h-screen flex items-center justify-center bg-base-200 px-4"
      >
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

      <%!-- Variant 2: Split Panel — static preview (live_component cannot be duplicated) --%>
      <div
        data-tw-variant="Split Panel"
        hidden
        class="min-h-screen flex"
      >
        <div class="hidden lg:flex flex-col items-center justify-center flex-1 bg-primary text-primary-content px-12">
          <div class="max-w-sm text-center space-y-4">
            <div class="flex items-center justify-center gap-3 mb-8">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="w-10 h-10"
                viewBox="0 0 24 24"
                fill="currentColor"
              >
                <path
                  fill-rule="evenodd"
                  d="M11.54 22.351l.07.04.028.016a.76.76 0 00.723 0l.028-.015.071-.041a16.975 16.975 0 001.144-.742 19.58 19.58 0 002.683-2.282c1.944-2.013 3.5-4.72 3.5-8.327a8 8 0 10-16 0c0 3.607 1.556 6.314 3.5 8.327a19.583 19.583 0 002.683 2.282 16.975 16.975 0 001.145.742zM12 13.5a3 3 0 100-6 3 3 0 000 6z"
                  clip-rule="evenodd"
                />
              </svg>
              <span class="text-4xl font-bold">Platser</span>
            </div>
            <p class="text-lg opacity-90 font-medium">Know where everyone is</p>
            <p class="text-sm opacity-70">
              Share your real-time location with friends and family at events and gatherings.
            </p>
          </div>
        </div>
        <div class="flex flex-col items-center justify-center flex-1 bg-base-100 px-4 py-12">
          <div class="w-full max-w-sm">
            <.auth_form_preview />
          </div>
        </div>
      </div>

      <%!-- Variant 3: Floating Minimal — static preview --%>
      <div
        data-tw-variant="Floating Minimal"
        hidden
        class="min-h-screen flex items-center justify-center px-4 bg-gradient-to-br from-base-200 to-base-300"
      >
        <div class="w-full max-w-sm">
          <div class="text-center mb-8">
            <span class="text-4xl font-bold text-base-content tracking-tight">Platser</span>
            <p class="text-base-content/50 text-sm mt-1">Sign in to continue</p>
          </div>
          <div class="bg-base-100/80 backdrop-blur-sm rounded-3xl shadow-2xl border border-base-300/50 p-8">
            <.auth_form_preview />
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Shared static form preview used in hidden variants to avoid live_component ID conflicts.
  # Matches the visual output of Components.SignIn with PlatserWeb.AuthOverrides applied.
  defp auth_form_preview(assigns) do
    ~H"""
    <div class="w-full mt-2 mb-2">
      <label class="text-xl font-bold text-base-content mb-4 block">Sign in</label>
      <div class="mb-3">
        <label class="block text-sm font-medium text-base-content/70 mb-1">Email</label>
        <input
          type="email"
          placeholder="you@example.com"
          disabled
          class="w-full px-3 py-2 text-sm border border-base-300 rounded-lg bg-base-100 text-base-content placeholder-base-content/40"
        />
      </div>
      <div class="mb-3">
        <label class="block text-sm font-medium text-base-content/70 mb-1">Password</label>
        <input
          type="password"
          placeholder="••••••••"
          disabled
          class="w-full px-3 py-2 text-sm border border-base-300 rounded-lg bg-base-100 text-base-content placeholder-base-content/40"
        />
      </div>
      <button
        disabled
        class="w-full py-2.5 px-4 bg-primary text-primary-content text-sm font-semibold rounded-lg opacity-80 mt-4 mb-2"
      >
        Sign in
      </button>
      <div class="flex flex-row justify-between text-sm font-medium mt-3">
        <span class="text-primary">Need an account?</span>
        <span class="text-primary">Forgot your password?</span>
      </div>
    </div>
    """
  end
end
