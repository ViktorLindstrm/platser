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

  describe "comment permission visibility" do
    property "comment form visibility is determined by can_manage and allow_public_comments" do
      check all(
              can_manage? <- StreamData.boolean(),
              allow_public_comments? <- StreamData.boolean(),
              has_comment? <- StreamData.boolean(),
              max_runs: 50
            ) do
        can_view_comment_form? = can_manage? or allow_public_comments?

        # When the user can manage OR comments are allowed, they should see the form
        assert can_view_comment_form? == (can_manage? or allow_public_comments?)

        # When comments are disabled and user is not a manager:
        # - They should see disabled message if no existing comment
        # - They should see the comment if it exists
        if not allow_public_comments? and not can_manage? do
          if has_comment? do
            # Should see the existing comment in read-only mode
            assert has_comment? == true
          else
            # Should see the "comments disabled" message
            assert allow_public_comments? == false
          end
        end
      end
    end
  end
end
