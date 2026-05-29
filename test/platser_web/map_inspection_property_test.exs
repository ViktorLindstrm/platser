defmodule PlatserWeb.MapInspectionPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PlatserWeb.MapInspection

  defp visibility_gen do
    StreamData.member_of([:private, :public])
  end

  defp kind_gen do
    StreamData.member_of([:poi, :geofence])
  end

  describe "kind labels" do
    property "each supported kind has a stable label" do
      check all(kind <- kind_gen(), max_runs: 10) do
        case kind do
          :poi -> assert MapInspection.kind_label(kind) == "Point of interest"
          :geofence -> assert MapInspection.kind_label(kind) == "Geofence"
        end
      end
    end
  end

  describe "status and visibility labels" do
    property "visibility determines the status and visibility copy" do
      check all(visibility <- visibility_gen(), max_runs: 10) do
        case visibility do
          :private ->
            assert MapInspection.status_label(visibility) == "Draft"
            assert MapInspection.visibility_label(visibility) == "Private"
            assert MapInspection.status(visibility) == :draft

          :public ->
            assert MapInspection.status_label(visibility) == "Published"
            assert MapInspection.visibility_label(visibility) == "Public"
            assert MapInspection.status(visibility) == :published
        end
      end
    end
  end

  describe "available actions" do
    property "focus is always available and manager actions match visibility" do
      check all(
              visibility <- visibility_gen(),
              can_manage? <- StreamData.boolean(),
              max_runs: 20
            ) do
        actions = MapInspection.available_actions(visibility, can_manage?)

        assert Enum.member?(actions, :focus)

        cond do
          can_manage? and visibility == :private ->
            assert actions == [:focus, :edit, :publish, :delete]

          can_manage? and visibility == :public ->
            assert actions == [:focus, :edit, :delete]

          true ->
            assert actions == [:focus]
        end
      end
    end
  end
end
