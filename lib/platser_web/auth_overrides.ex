defmodule PlatserWeb.AuthOverrides do
  @moduledoc """
  Custom AshAuthentication.Phoenix overrides that match the Platser design system.
  Uses CSS custom properties (base-100, primary, etc.) from the app theme.
  """

  use AshAuthentication.Phoenix.Overrides

  alias AshAuthentication.Phoenix.{
    Components,
    ConfirmLive,
    ResetLive,
    SignInLive,
    SignOutLive
  }

  # The outer page wrapper is controlled by our custom LiveView,
  # so these root classes are intentionally left empty.
  override SignInLive do
    set :root_class, ""
  end

  override SignOutLive do
    set :root_class, ""
  end

  override ConfirmLive do
    set :root_class, ""
  end

  override ResetLive do
    set :root_class, ""
  end

  # The sign-in component itself should just be full-width within our wrapper.
  # Banner is disabled here — each layout variant provides its own header.
  override Components.SignIn do
    set :root_class, "w-full"
    set :strategy_class, "w-full"
    set :show_banner, false
    set :authentication_error_container_class, "text-error text-center text-sm my-2"
    set :authentication_error_text_class, ""
    set :strategy_display_order, :forms_first
  end

  # Disable the built-in banner — each layout variant has its own header section.
  override Components.Banner do
    set :root_class, ""
    set :href_url, nil
    set :image_url, nil
    set :dark_image_url, nil
    set :text, nil
    set :text_class, nil
  end

  # Input fields styled to match the app's design system.
  override Components.Password.Input do
    set :field_class, "mb-3"
    set :label_class, "block text-sm font-medium text-base-content/70 mb-1"

    set :input_class,
        "w-full px-3 py-2 text-sm border border-base-300 rounded-lg bg-base-100 text-base-content placeholder-base-content/40 focus:outline-none focus:ring-2 focus:ring-primary/50 focus:border-primary transition-colors"

    set :input_class_with_error,
        "w-full px-3 py-2 text-sm border border-error rounded-lg bg-base-100 text-base-content placeholder-base-content/40 focus:outline-none focus:ring-2 focus:ring-error/50 focus:border-error transition-colors"

    set :submit_class,
        "w-full py-2.5 px-4 bg-primary text-primary-content text-sm font-semibold rounded-lg hover:bg-primary/90 focus:outline-none focus:ring-2 focus:ring-primary/50 active:scale-[0.98] transition-all cursor-pointer mt-4 mb-2"

    set :error_ul, "text-error text-sm font-light my-1 italic"
    set :error_li, nil
    set :input_debounce, 350
    set :identity_input_label, "Email"
    set :password_input_label, "Password"
    set :password_confirmation_input_label, "Confirm Password"
  end

  override Components.Password do
    set :root_class, "mt-2 mb-2"
    set :interstitial_class, "flex flex-row justify-between text-sm font-medium mt-3"
    set :toggler_class, "text-primary hover:text-primary/80 transition-colors"
    set :register_extra_component, &PlatserWeb.AuthComponents.register_extra/1
    set :sign_in_toggle_text, "Already have an account?"
    set :register_toggle_text, "Need an account?"
    set :reset_toggle_text, "Forgot your password?"
    set :show_first, :sign_in
    set :hide_class, "hidden"
  end

  override Components.Password.SignInForm do
    set :root_class, ""
    set :label_class, "text-xl font-bold text-base-content mb-4 block"
    set :form_class, ""
    set :slot_class, "my-3"
    set :button_text, "Sign in"
    set :disable_button_text, "Signing in…"
  end

  override Components.Password.RegisterForm do
    set :root_class, ""
    set :label_class, "text-xl font-bold text-base-content mb-4 block"
    set :form_class, ""
    set :slot_class, "my-3"
    set :button_text, "Create account"
    set :disable_button_text, "Creating account…"
  end

  override Components.Password.ResetForm do
    set :root_class, ""
    set :label_class, "text-xl font-bold text-base-content mb-4 block"
    set :form_class, ""
    set :slot_class, "my-3"
    set :button_text, "Send reset link"
    set :disable_button_text, "Sending…"

    set :reset_flash_text,
        "If an account with that email exists, you'll receive a password reset link shortly."
  end

  override Components.Reset do
    set :root_class, "w-full"
    set :strategy_class, "w-full"
  end

  override Components.Confirm do
    set :root_class, "w-full"
    set :strategy_class, "w-full"
  end
end
