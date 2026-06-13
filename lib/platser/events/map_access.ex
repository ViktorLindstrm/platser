defmodule Platser.Events.MapAccess do
  @moduledoc """
  Map-scoped membership roles and capabilities.

  Legacy roles are accepted for reads during the migration window, but new
  writes should use `:full_manager`, `:content_manager`, or `:participant`.
  """

  @type legacy_role :: :admin | :member
  @type role :: :full_manager | :content_manager | :participant
  @type compatible_role :: role() | legacy_role()

  @type capability ::
          :read_event
          | :read_public_map_items
          | :read_private_map_items
          | :create_map_items
          | :publish_own_map_items
          | :manage_any_map_item
          | :manage_event_settings
          | :manage_members
          | :manage_join_code
          | :manage_permissions
          | :view_manager_audit

  @roles [:full_manager, :content_manager, :participant]
  @compatible_roles [:full_manager, :content_manager, :participant, :admin, :member]
  @full_manager_capabilities [
    :read_event,
    :read_public_map_items,
    :read_private_map_items,
    :create_map_items,
    :publish_own_map_items,
    :manage_any_map_item,
    :manage_event_settings,
    :manage_members,
    :manage_join_code,
    :manage_permissions,
    :view_manager_audit
  ]
  @content_manager_capabilities [
    :read_event,
    :read_public_map_items,
    :create_map_items,
    :publish_own_map_items,
    :manage_any_map_item,
    :read_private_map_items
  ]
  @participant_capabilities [
    :read_event,
    :read_public_map_items,
    :create_map_items,
    :publish_own_map_items
  ]

  @spec roles() :: [role()]
  def roles, do: @roles

  @spec compatible_roles() :: [compatible_role()]
  def compatible_roles, do: @compatible_roles

  @spec normalize(compatible_role()) :: role()
  def normalize(:admin), do: :full_manager
  def normalize(:member), do: :participant
  def normalize(role) when role in @roles, do: role

  @spec parse_role(String.t() | atom()) :: {:ok, role()} | :error
  def parse_role(role) when role in @roles, do: {:ok, role}

  def parse_role(role) when is_binary(role) do
    case role do
      "full_manager" -> {:ok, :full_manager}
      "content_manager" -> {:ok, :content_manager}
      "participant" -> {:ok, :participant}
      _ -> :error
    end
  end

  def parse_role(_role), do: :error

  @spec can?(compatible_role(), capability()) :: boolean()
  def can?(role, capability), do: capability in capabilities(normalize(role))

  @spec roles_for_capability(capability()) :: [compatible_role()]
  def roles_for_capability(capability) do
    Enum.filter(@compatible_roles, &can?(&1, capability))
  end

  @spec full_manager?(compatible_role()) :: boolean()
  def full_manager?(role), do: normalize(role) == :full_manager

  @spec manager?(compatible_role()) :: boolean()
  def manager?(role), do: normalize(role) in [:full_manager, :content_manager]

  @spec manager_role?(compatible_role()) :: boolean()
  def manager_role?(role), do: normalize(role) in [:full_manager, :content_manager]

  @spec label(compatible_role()) :: String.t()
  def label(role) do
    case normalize(role) do
      :full_manager -> "Map manager"
      :content_manager -> "Contributor manager"
      :participant -> "Member"
    end
  end

  @spec capabilities(role()) :: [capability()]
  defp capabilities(:full_manager), do: @full_manager_capabilities
  defp capabilities(:content_manager), do: @content_manager_capabilities
  defp capabilities(:participant), do: @participant_capabilities
end
