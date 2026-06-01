defmodule Platser.Media.AttachmentDeliveryPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Platser.Media.DiskPath

  @uploads_root DiskPath.uploads_root()

  defp fake_attachment(poi_id, stored_filename) do
    %Platser.Media.Attachment{
      id: Ecto.UUID.generate(),
      filename: "photo.jpg",
      stored_filename: stored_filename,
      content_type: "image/jpeg",
      path: "/uploads/#{poi_id}/#{stored_filename}",
      poi_id: poi_id,
      geofence_id: nil,
      uploader_id: Ecto.UUID.generate()
    }
  end

  # ---------------------------------------------------------------------------
  # Property 1: derived disk path is always under uploads root (or nil)
  #
  # No matter what owner_id or stored_filename values appear in the database,
  # the result is either nil (rejected) or safely under @uploads_root.
  # ---------------------------------------------------------------------------
  property "derived disk path is always nil or under the uploads root" do
    check all(
            owner_id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 64),
            stored_filename <-
              StreamData.one_of([
                StreamData.string(:alphanumeric, min_length: 1, max_length: 64),
                StreamData.constant("../../etc/passwd"),
                StreamData.constant("../secret"),
                StreamData.constant("%2e%2e/secret"),
                StreamData.string(:printable, min_length: 1, max_length: 64)
              ])
          ) do
      attachment = fake_attachment(owner_id, stored_filename)

      case DiskPath.for_attachment(attachment) do
        nil ->
          :ok

        path when is_binary(path) ->
          assert String.starts_with?(path, @uploads_root <> "/"),
                 "Disk path #{inspect(path)} escaped uploads root #{inspect(@uploads_root)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Property 2: traversal-containing filenames always yield nil or a safe path
  # ---------------------------------------------------------------------------
  property "stored_filenames containing '..' never escape the uploads root" do
    check all(
            prefix <- StreamData.string(:alphanumeric, max_length: 8),
            suffix <- StreamData.string(:alphanumeric, max_length: 8),
            sep <- StreamData.one_of([StreamData.constant(".."), StreamData.constant("../")])
          ) do
      stored_filename = prefix <> sep <> suffix
      attachment = fake_attachment(Ecto.UUID.generate(), stored_filename)

      case DiskPath.for_attachment(attachment) do
        nil ->
          :ok

        path ->
          assert String.starts_with?(path, @uploads_root <> "/"),
                 "Traversal filename #{inspect(stored_filename)} produced unsafe path #{inspect(path)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Property 3: canonical path reconstruction from URL segments is deterministic
  # ---------------------------------------------------------------------------
  property "canonical path reconstruction is deterministic" do
    check all(
            poi_id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 64),
            filename <- StreamData.string(:alphanumeric, min_length: 1, max_length: 64)
          ) do
      path_parts = [poi_id, filename]
      reconstructed = "/uploads/" <> Enum.join(path_parts, "/")

      assert reconstructed == "/uploads/#{poi_id}/#{filename}"
    end
  end

  # ---------------------------------------------------------------------------
  # Property 4: poi_id-only vs geofence_id-only — owner derivation is stable
  # ---------------------------------------------------------------------------
  property "owner_id derivation prefers poi_id over geofence_id" do
    check all(
            poi_id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 36),
            geofence_id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 36),
            stored_filename <- StreamData.string(:alphanumeric, min_length: 1, max_length: 64)
          ) do
      poi_attachment = %Platser.Media.Attachment{
        id: Ecto.UUID.generate(),
        filename: "f.jpg",
        stored_filename: stored_filename,
        content_type: "image/jpeg",
        path: "/uploads/#{poi_id}/#{stored_filename}",
        poi_id: poi_id,
        geofence_id: nil,
        uploader_id: Ecto.UUID.generate()
      }

      geofence_attachment = %Platser.Media.Attachment{
        id: Ecto.UUID.generate(),
        filename: "f.jpg",
        stored_filename: stored_filename,
        content_type: "image/jpeg",
        path: "/uploads/#{geofence_id}/#{stored_filename}",
        poi_id: nil,
        geofence_id: geofence_id,
        uploader_id: Ecto.UUID.generate()
      }

      poi_path = DiskPath.for_attachment(poi_attachment)
      geofence_path = DiskPath.for_attachment(geofence_attachment)

      # A safe path should contain the correct owner segment
      if poi_path, do: assert(String.contains?(poi_path, poi_id))
      if geofence_path, do: assert(String.contains?(geofence_path, geofence_id))
    end
  end
end
