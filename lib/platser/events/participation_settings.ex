defmodule Platser.Events.ParticipationSettings do
  @moduledoc """
  Event-level participant affordance settings.
  """

  @type setting :: :comments | :check_ins | :live_location
  @type setting_value :: boolean()

  @settings [:comments, :check_ins, :live_location]

  @spec settings() :: [setting()]
  def settings, do: @settings

  @spec parse_setting(String.t() | atom()) :: {:ok, setting()} | :error
  def parse_setting(setting) when setting in @settings, do: {:ok, setting}

  def parse_setting(setting) when is_binary(setting) do
    case setting do
      "comments" -> {:ok, :comments}
      "check_ins" -> {:ok, :check_ins}
      "live_location" -> {:ok, :live_location}
      _ -> :error
    end
  end

  def parse_setting(_setting), do: :error

  @spec parse_boolean(String.t() | boolean()) :: {:ok, boolean()} | :error
  def parse_boolean(value) when is_boolean(value), do: {:ok, value}
  def parse_boolean("true"), do: {:ok, true}
  def parse_boolean("false"), do: {:ok, false}
  def parse_boolean(_value), do: :error
end
