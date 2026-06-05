defmodule PlatserWeb.UpgradeLive do
  use PlatserWeb, :live_view

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    unless user.is_guest do
      {:ok, push_navigate(socket, to: ~p"/events")}
    else
      {:ok,
       assign(socket, display_name: user.display_name, email: "", page_title: "Upgrade Account")}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_user}>
      <div class="min-h-screen flex items-center justify-center px-4 py-12">
        <div class="max-w-md w-full space-y-6">
          <div class="text-center">
            <div class="w-16 h-16 bg-primary/10 rounded-full flex items-center justify-center mx-auto mb-4">
              <.icon name="hero-user-plus" class="w-8 h-8 text-primary" />
            </div>
            <h1 class="text-2xl font-bold text-base-content">Create Your Account</h1>
            <p class="mt-2 text-base-content/60">
              Save your guest session and unlock the full experience. Your event membership and data are preserved.
            </p>
          </div>

          <div class="bg-base-200 rounded-2xl p-8 space-y-6">
            <.form
              for={%{}}
              action={~p"/upgrade-account"}
              method="post"
              id="upgrade-form"
            >
              <div class="space-y-4">
                <div>
                  <label class="block text-sm font-medium text-base-content/70 mb-1">
                    Display Name
                  </label>
                  <input
                    id="display_name"
                    name="display_name"
                    type="text"
                    value={@display_name}
                    class="w-full rounded-xl border border-base-300 bg-base-100 px-4 py-3 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/50 transition-all"
                    placeholder="Your name"
                  />
                </div>
                <div>
                  <label class="block text-sm font-medium text-base-content/70 mb-1">
                    Email Address
                  </label>
                  <input
                    id="email"
                    name="email"
                    type="email"
                    value={@email}
                    class="w-full rounded-xl border border-base-300 bg-base-100 px-4 py-3 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/50 transition-all"
                    placeholder="you@example.com"
                    autocomplete="email"
                  />
                </div>
                <div>
                  <label class="block text-sm font-medium text-base-content/70 mb-1">
                    Password
                  </label>
                  <input
                    id="password"
                    name="password"
                    type="password"
                    class="w-full rounded-xl border border-base-300 bg-base-100 px-4 py-3 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/50 transition-all"
                    placeholder="••••••••"
                    autocomplete="new-password"
                  />
                </div>
                <div>
                  <label class="block text-sm font-medium text-base-content/70 mb-1">
                    Confirm Password
                  </label>
                  <input
                    id="password_confirmation"
                    name="password_confirmation"
                    type="password"
                    class="w-full rounded-xl border border-base-300 bg-base-100 px-4 py-3 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/50 transition-all"
                    placeholder="••••••••"
                    autocomplete="new-password"
                  />
                </div>
              </div>

              <button
                type="submit"
                class="mt-6 w-full py-3 px-6 rounded-xl bg-primary text-primary-content font-semibold hover:brightness-110 active:scale-95 transition-all"
              >
                Create Account
              </button>
            </.form>
          </div>

          <p class="text-center text-sm text-base-content/50">
            Already have an account?
            <.link navigate={~p"/sign-in"} class="text-primary hover:underline">
              Sign in
            </.link>
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
