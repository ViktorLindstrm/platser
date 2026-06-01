defmodule Platser.Media.DiskPath do
  @moduledoc """
  Safe disk path derivation for uploaded media files.

  Derives the on-disk absolute path from canonical `Media.Attachment` fields
  (never from raw URL input) and validates it stays within the uploads root.
  """

  @uploads_root Path.expand("priv/static/uploads", :code.priv_dir(:platser))

  @doc """
  Returns the uploads root directory as an absolute path.
  """
  @spec uploads_root() :: String.t()
  def uploads_root, do: @uploads_root

  @doc """
  Returns the safe absolute disk path for an attachment, or `nil` if the
  derived path would escape the uploads root (path traversal guard).

  The path is derived from `attachment.poi_id || attachment.geofence_id`
  and `attachment.stored_filename`. The raw URL is never used.
  """
  @spec for_attachment(Platser.Media.Attachment.t()) :: String.t() | nil
  def for_attachment(attachment) do
    owner_id = attachment.poi_id || attachment.geofence_id

    candidate =
      Path.expand(Path.join([@uploads_root, to_string(owner_id), attachment.stored_filename]))

    if String.starts_with?(candidate, @uploads_root <> "/"), do: candidate, else: nil
  end
end
