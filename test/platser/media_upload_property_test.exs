defmodule Platser.MediaUploadPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Platser.Media.Upload

  property "generated attachment metadata never includes the client filename" do
    check all(
            owner_id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 36),
            upload_id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 36),
            client_name <- client_filename_gen(),
            format <- StreamData.member_of([:jpeg, :png, :webp])
          ) do
      metadata = Upload.build_metadata(owner_id, format, upload_id)

      refute String.contains?(metadata.stored_filename, client_name)
      refute String.contains?(metadata.path, client_name)
      assert metadata.filename in ["image.jpg", "image.png", "image.webp"]
      assert String.starts_with?(metadata.path, "/uploads/#{owner_id}/#{upload_id}.")
      assert metadata.stored_filename =~ ~r/^[A-Za-z0-9]+\.(jpg|png|webp)$/
    end
  end

  property "sanitized accepted image bytes do not contain metadata markers" do
    check all(format <- StreamData.member_of([:jpeg, :png, :webp])) do
      {:ok, sanitized} = Upload.sanitize(image_with_metadata(format), format)

      refute Upload.contains_sensitive_metadata?(sanitized)
      assert byte_size(sanitized) > 0
    end
  end

  property "invalid or truncated image bytes are rejected" do
    check all(
            format <- StreamData.member_of([:jpeg, :png, :webp]),
            bytes <- StreamData.binary(min_length: 0, max_length: 24)
          ) do
      assert Upload.sanitize(bytes, format) == {:error, :invalid_image}
    end
  end

  @spec client_filename_gen() :: StreamData.t(String.t())
  defp client_filename_gen do
    StreamData.map(
      StreamData.string(:printable, min_length: 1, max_length: 32),
      fn name -> name <> ".jpg" end
    )
  end

  @spec image_with_metadata(Upload.image_format()) :: binary()
  defp image_with_metadata(:jpeg) do
    <<0xFF, 0xD8>> <>
      jpeg_segment(0xE1, "Exif\x00\x00private-gps") <>
      jpeg_segment(0xFE, "XMP private comment") <>
      jpeg_segment(0xDB, <<0::64>>) <>
      <<0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 63, 0, 1, 2, 3, 0xFF, 0xD9>>
  end

  defp image_with_metadata(:png) do
    signature = <<137, 80, 78, 71, 13, 10, 26, 10>>

    signature <>
      png_chunk("IHDR", <<1::32, 1::32, 8, 2, 0, 0, 0>>) <>
      png_chunk("eXIf", "Exif private gps") <>
      png_chunk("tEXt", "private filename") <>
      png_chunk("IDAT", <<120, 156, 99, 0, 0, 0, 2, 0, 1>>) <>
      png_chunk("IEND", "")
  end

  defp image_with_metadata(:webp) do
    chunks =
      webp_chunk("VP8X", <<0b0011_1100, 0::24, 1::24-little, 1::24-little>>) <>
        webp_chunk("EXIF", "Exif private gps") <>
        webp_chunk("XMP ", "http://ns.adobe.com/xap/1.0/") <>
        webp_chunk("VP8 ", <<157, 1, 42, 1::16-little, 1::16-little, 0>>)

    "RIFF" <> <<byte_size("WEBP" <> chunks)::32-little>> <> "WEBP" <> chunks
  end

  @spec jpeg_segment(0..255, binary()) :: binary()
  defp jpeg_segment(marker, data), do: <<0xFF, marker, byte_size(data) + 2::16>> <> data

  @spec png_chunk(binary(), binary()) :: binary()
  defp png_chunk(type, data), do: <<byte_size(data)::32>> <> type <> data <> <<0::32>>

  @spec webp_chunk(binary(), binary()) :: binary()
  defp webp_chunk(type, data) do
    pad = if rem(byte_size(data), 2) == 1, do: <<0>>, else: ""
    type <> <<byte_size(data)::32-little>> <> data <> pad
  end
end
