defmodule Platser.MediaAttachmentMetadataPropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  alias Platser.Accounts.User
  alias Platser.Events.Event
  alias Platser.Map, as: PlatserMap
  alias Platser.Media

  property "attachment create accepts only opaque storage metadata" do
    check all(
            client_stem <- StreamData.string(:alphanumeric, min_length: 3, max_length: 18),
            max_runs: 5
          ) do
      user = create_user(client_stem)
      event = create_event(user)
      poi = create_poi(user, event)
      stored_filename = "#{Ecto.UUID.generate()}.jpg"

      assert {:ok, attachment} =
               Media.create_attachment(
                 %{
                   filename: "image.jpg",
                   stored_filename: stored_filename,
                   content_type: "image/jpeg",
                   path: "/uploads/#{poi.id}/#{stored_filename}",
                   poi_id: poi.id
                 },
                 actor: user,
                 authorize?: false
               )

      refute String.contains?(attachment.path, client_stem)

      assert {:error, %Ash.Error.Invalid{}} =
               Media.create_attachment(
                 %{
                   filename: "#{client_stem}.jpg",
                   stored_filename: "#{Ecto.UUID.generate()}_#{client_stem}.jpg",
                   content_type: "image/jpeg",
                   path: "/uploads/#{poi.id}/#{Ecto.UUID.generate()}_#{client_stem}.jpg",
                   poi_id: poi.id
                 },
                 actor: user,
                 authorize?: false
               )
    end
  end

  @spec create_user(String.t()) :: User.t()
  defp create_user(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "media_metadata_#{tag}_#{n}@example.com",
          display_name: "Media Metadata #{tag} #{n}",
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end

  @spec create_event(User.t()) :: Event.t()
  defp create_event(user) do
    {:ok, event} =
      Ash.create(
        Event,
        %{
          name: "Media Metadata Event",
          description: "desc",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: user
      )

    event
  end

  @spec create_poi(User.t(), Event.t()) :: Platser.Map.Poi.t()
  defp create_poi(user, event) do
    {:ok, poi} =
      PlatserMap.create_poi(
        %{
          name: "Media Metadata POI",
          description: "desc",
          category: :viewpoint,
          location: %Geo.Point{coordinates: {174.7633, -36.8485}, srid: 4326},
          event_id: event.id
        },
        actor: user
      )

    poi
  end
end
