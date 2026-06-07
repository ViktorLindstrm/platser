defmodule PlatserWeb.AuthComponents do
  @moduledoc """
  Extra fields for AshAuthentication.Phoenix forms.
  """

  use PlatserWeb, :html

  attr :form, :any, required: true

  @spec register_extra(map()) :: Phoenix.LiveView.Rendered.t()
  def register_extra(assigns) do
    ~H"""
    <.input
      field={@form[:display_name]}
      type="text"
      label="Display name"
      autocomplete="name"
      required
    />
    """
  end
end
