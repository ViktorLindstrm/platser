defmodule Platser.GeofencePropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  alias Platser.Map, as: PlatserMap

  @moduledoc """
  StreamData property tests for Map.Geofence resource.
  """

  # ── Generators ──────────────────────────────────────────────────────────────

  defp vertex_gen do
    StreamData.tuple({
      StreamData.float(min: -170.0, max: 170.0),
      StreamData.float(min: -80.0, max: 80.0)
    })
  end

  defp valid_polygon_gen do
    # Generate a right-triangle with random corner and size — guaranteed non-degenerate
    StreamData.map(
      StreamData.tuple({
        StreamData.float(min: -170.0, max: 170.0),
        StreamData.float(min: -80.0, max: 80.0),
        StreamData.float(min: 0.01, max: 5.0)
      }),
      fn {lng, lat, size} ->
        ring = [
          {lng, lat},
          {lng + size, lat},
          {lng + size, lat + size},
          {lng, lat}
        ]

        %Geo.Polygon{coordinates: [ring], srid: 4326}
      end
    )
  end

  defp short_ring_gen do
    StreamData.integer(0..2)
    |> StreamData.bind(fn count ->
      StreamData.list_of(vertex_gen(), length: count)
      |> StreamData.map(fn verts ->
        case verts do
          [] -> []
          _ -> verts ++ [List.first(verts)]
        end
      end)
    end)
  end

  defp invalid_polygon_gen do
    StreamData.map(short_ring_gen(), fn ring ->
      %Geo.Polygon{coordinates: [ring], srid: 4326}
    end)
  end

  defp purpose_gen do
    StreamData.one_of([
      StreamData.constant(:boundary),
      StreamData.constant(:meeting_zone),
      StreamData.constant(:restricted),
      StreamData.constant(:camp_area),
      StreamData.constant(:other)
    ])
  end

  defp invalid_purpose_gen do
    StreamData.filter(StreamData.atom(:alphanumeric), fn a ->
      a not in [:boundary, :meeting_zone, :restricted, :camp_area, :other]
    end)
  end

  defp valid_hex_color_gen do
    hex_char = StreamData.member_of(~c"0123456789abcdef")

    StreamData.list_of(hex_char, length: 6)
    |> StreamData.map(fn chars -> "#" <> List.to_string(chars) end)
  end

  defp invalid_hex_color_gen do
    StreamData.one_of([
      StreamData.constant("red"),
      StreamData.constant(""),
      StreamData.constant("#GGGGGG"),
      StreamData.constant("ff0000"),
      StreamData.constant("#12345"),
      StreamData.constant("#1234567")
    ])
  end

  # ── Fixtures ─────────────────────────────────────────────────────────────────

  defp create_user do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        Platser.Accounts.User,
        %{
          email: "geofence_test_#{n}@example.com",
          display_name: "Test User #{n}",
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end

  defp create_event_with_member do
    user = create_user()

    {:ok, event} =
      Ash.create(
        Platser.Events.Event,
        %{
          name: "Test Event",
          description: "desc",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: user
      )

    {user, event}
  end

  # ── Tests ──────────────────────────────────────────────────────────────────

  describe "polygon vertex count" do
    property "polygons with < 3 unique vertices are always rejected" do
      check all(polygon <- invalid_polygon_gen(), max_runs: 50) do
        {user, event} = create_event_with_member()

        result =
          PlatserMap.create_geofence(
            %{
              name: "Test Geofence",
              purpose: :boundary,
              color: "#3B82F6",
              geometry: polygon,
              event_id: event.id
            },
            actor: user
          )

        assert {:error, _} = result
      end
    end

    property "boundary polygons with >= 3 valid WGS-84 vertices are accepted and auto-published" do
      check all(polygon <- valid_polygon_gen(), max_runs: 30) do
        {user, event} = create_event_with_member()

        result =
          PlatserMap.create_geofence(
            %{
              name: "Test Geofence",
              purpose: :boundary,
              color: "#3B82F6",
              geometry: polygon,
              event_id: event.id
            },
            actor: user
          )

        assert {:ok, geofence} = result
        assert geofence.visibility == :public
        assert not is_nil(geofence.published_at)
      end
    end
  end

  describe "boundary uniqueness" do
    property "creating a second boundary geofence for the same event always fails" do
      check all(
              first_polygon <- valid_polygon_gen(),
              second_polygon <- valid_polygon_gen(),
              max_runs: 20
            ) do
        {user, event} = create_event_with_member()

        assert {:ok, _first} =
                 PlatserMap.create_geofence(
                   %{
                     name: "Boundary One",
                     purpose: :boundary,
                     color: "#3B82F6",
                     geometry: first_polygon,
                     event_id: event.id
                   },
                   actor: user
                 )

        assert {:error, _} =
                 PlatserMap.create_geofence(
                   %{
                     name: "Boundary Two",
                     purpose: :boundary,
                     color: "#3B82F6",
                     geometry: second_polygon,
                     event_id: event.id
                   },
                   actor: user
                 )
      end
    end
  end

  describe "purpose enum" do
    property "any valid purpose enum value is accepted" do
      check all(purpose <- purpose_gen(), max_runs: 20) do
        {user, event} = create_event_with_member()

        polygon = %Geo.Polygon{
          coordinates: [
            [{0.0, 0.0}, {1.0, 0.0}, {1.0, 1.0}, {0.0, 0.0}]
          ],
          srid: 4326
        }

        result =
          PlatserMap.create_geofence(
            %{
              name: "Test",
              purpose: purpose,
              color: "#3B82F6",
              geometry: polygon,
              event_id: event.id
            },
            actor: user
          )

        assert {:ok, _} = result
      end
    end

    property "values outside the purpose enum are rejected" do
      check all(purpose <- invalid_purpose_gen(), max_runs: 20) do
        {user, event} = create_event_with_member()

        polygon = %Geo.Polygon{
          coordinates: [
            [{0.0, 0.0}, {1.0, 0.0}, {1.0, 1.0}, {0.0, 0.0}]
          ],
          srid: 4326
        }

        result =
          PlatserMap.create_geofence(
            %{
              name: "Test",
              purpose: purpose,
              color: "#3B82F6",
              geometry: polygon,
              event_id: event.id
            },
            actor: user
          )

        assert {:error, _} = result
      end
    end
  end

  describe "Geofence.publish/1 idempotency" do
    property "publishing twice inserts exactly one Activity.Entry" do
      check all(polygon <- valid_polygon_gen(), max_runs: 10) do
        {user, event} = create_event_with_member()

        {:ok, geofence} =
          PlatserMap.create_geofence(
            %{
              name: "Publish Test",
              purpose: :meeting_zone,
              color: "#3B82F6",
              geometry: polygon,
              event_id: event.id
            },
            actor: user
          )

        assert {:ok, published} = PlatserMap.publish_geofence(geofence, actor: user)

        assert {:error, _} = PlatserMap.publish_geofence(published, actor: user)

        {:ok, entries} =
          Platser.Activity.list_entries_for_event(event.id, actor: user)

        geofence_publish_entries =
          Enum.filter(entries, fn e ->
            e.action == :geofence_published and e.subject_id == geofence.id
          end)

        assert length(geofence_publish_entries) == 1
      end
    end
  end

  describe "color hex validation" do
    property "valid hex color strings are stored as-is" do
      check all(color <- valid_hex_color_gen(), max_runs: 30) do
        {user, event} = create_event_with_member()

        polygon = %Geo.Polygon{
          coordinates: [
            [{0.0, 0.0}, {1.0, 0.0}, {1.0, 1.0}, {0.0, 0.0}]
          ],
          srid: 4326
        }

        result =
          PlatserMap.create_geofence(
            %{
              name: "Color Test",
              purpose: :boundary,
              color: color,
              geometry: polygon,
              event_id: event.id
            },
            actor: user
          )

        assert {:ok, geofence} = result
        assert geofence.color == color
      end
    end

    property "invalid hex color formats are rejected" do
      check all(color <- invalid_hex_color_gen(), max_runs: 20) do
        {user, event} = create_event_with_member()

        polygon = %Geo.Polygon{
          coordinates: [
            [{0.0, 0.0}, {1.0, 0.0}, {1.0, 1.0}, {0.0, 0.0}]
          ],
          srid: 4326
        }

        result =
          PlatserMap.create_geofence(
            %{
              name: "Color Test",
              purpose: :boundary,
              color: color,
              geometry: polygon,
              event_id: event.id
            },
            actor: user
          )

        assert {:error, _} = result
      end
    end
  end

  describe "description field" do
    property "description is stored and retrieved unchanged when provided" do
      check all(
              description <- StreamData.string(:printable, min_length: 1, max_length: 500),
              max_runs: 25
            ) do
        {user, event} = create_event_with_member()

        polygon = %Geo.Polygon{
          coordinates: [
            [{0.0, 0.0}, {1.0, 0.0}, {1.0, 1.0}, {0.0, 0.0}]
          ],
          srid: 4326
        }

        assert {:ok, geofence} =
                 PlatserMap.create_geofence(
                   %{
                     name: "Desc Test",
                     purpose: :boundary,
                     color: "#3B82F6",
                     geometry: polygon,
                     event_id: event.id,
                     description: description
                   },
                   actor: user
                 )

        assert geofence.description == description
      end
    end

    property "description defaults to nil when not provided" do
      check all(polygon <- valid_polygon_gen(), max_runs: 15) do
        {user, event} = create_event_with_member()

        assert {:ok, geofence} =
                 PlatserMap.create_geofence(
                   %{
                     name: "No Desc",
                     purpose: :boundary,
                     color: "#3B82F6",
                     geometry: polygon,
                     event_id: event.id
                   },
                   actor: user
                 )

        assert is_nil(geofence.description)
      end
    end
  end

  describe "comment field" do
    property "comment set via update_comment is persisted and retrieved" do
      check all(
              comment <- StreamData.string(:printable, min_length: 1, max_length: 1000),
              max_runs: 25
            ) do
        {user, event} = create_event_with_member()

        polygon = %Geo.Polygon{
          coordinates: [
            [{0.0, 0.0}, {1.0, 0.0}, {1.0, 1.0}, {0.0, 0.0}]
          ],
          srid: 4326
        }

        {:ok, geofence} =
          PlatserMap.create_geofence(
            %{
              name: "Comment Test",
              purpose: :boundary,
              color: "#3B82F6",
              geometry: polygon,
              event_id: event.id
            },
            actor: user
          )

        assert {:ok, updated} =
                 PlatserMap.update_geofence_comment(
                   geofence,
                   %{comment: comment},
                   actor: user
                 )

        assert updated.comment == comment

        assert {:ok, fetched} = PlatserMap.get_geofence(geofence.id, actor: user)
        assert fetched.comment == comment
      end
    end

    property "comment can be cleared by setting nil" do
      check all(polygon <- valid_polygon_gen(), max_runs: 10) do
        {user, event} = create_event_with_member()

        {:ok, geofence} =
          PlatserMap.create_geofence(
            %{
              name: "Comment Clear",
              purpose: :boundary,
              color: "#3B82F6",
              geometry: polygon,
              event_id: event.id,
              comment: "initial comment"
            },
            actor: user
          )

        assert {:ok, updated} =
                 PlatserMap.update_geofence_comment(
                   geofence,
                   %{comment: nil},
                   actor: user
                 )

        assert is_nil(updated.comment)
      end
    end
  end

  describe "geofence attachments" do
    property "attachments created for a geofence are listed back" do
      check all(
              filename <- StreamData.string(:alphanumeric, min_length: 3, max_length: 40),
              max_runs: 15
            ) do
        {user, event} = create_event_with_member()

        polygon = %Geo.Polygon{
          coordinates: [
            [{0.0, 0.0}, {1.0, 0.0}, {1.0, 1.0}, {0.0, 0.0}]
          ],
          srid: 4326
        }

        {:ok, geofence} =
          PlatserMap.create_geofence(
            %{
              name: "Attachment Test",
              purpose: :boundary,
              color: "#3B82F6",
              geometry: polygon,
              event_id: event.id
            },
            actor: user
          )

        stored = "#{Ecto.UUID.generate()}_#{filename}.jpg"

        assert {:ok, attachment} =
                 Platser.Media.create_geofence_attachment(
                   %{
                     filename: "#{filename}.jpg",
                     stored_filename: stored,
                     content_type: "image/jpeg",
                     path: "/uploads/#{geofence.id}/#{stored}",
                     geofence_id: geofence.id
                   },
                   actor: user,
                   authorize?: false
                 )

        assert attachment.geofence_id == geofence.id

        assert {:ok, attachments} =
                 Platser.Media.list_attachments_for_geofence(geofence.id, actor: user)

        ids = Enum.map(attachments, & &1.id)
        assert attachment.id in ids
      end
    end

    property "attachments belong to exactly one parent (geofence xor poi)" do
      check all(polygon <- valid_polygon_gen(), max_runs: 10) do
        {user, event} = create_event_with_member()

        {:ok, geofence} =
          PlatserMap.create_geofence(
            %{
              name: "XOR Test",
              purpose: :boundary,
              color: "#3B82F6",
              geometry: polygon,
              event_id: event.id
            },
            actor: user
          )

        stored = "#{Ecto.UUID.generate()}_test.jpg"

        {:ok, attachment} =
          Platser.Media.create_geofence_attachment(
            %{
              filename: "test.jpg",
              stored_filename: stored,
              content_type: "image/jpeg",
              path: "/uploads/#{geofence.id}/#{stored}",
              geofence_id: geofence.id
            },
            actor: user,
            authorize?: false
          )

        assert not is_nil(attachment.geofence_id)
        assert is_nil(attachment.poi_id)
      end
    end
  end
end
