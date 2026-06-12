defmodule Platser.Media.Upload do
  @moduledoc """
  Sanitizes uploaded image files and writes privacy-safe media objects to disk.
  """

  alias Platser.Media.DiskPath

  @type image_format :: :jpeg | :png | :webp
  @type error_reason ::
          :read_failed
          | :write_failed
          | :unsupported_extension
          | :unsupported_content_type
          | :invalid_image
  @type stored_photo :: %{
          filename: String.t(),
          stored_filename: String.t(),
          content_type: String.t(),
          path: String.t()
        }

  @jpeg_exts ~w(.jpg .jpeg)
  @png_exts ~w(.png)
  @webp_exts ~w(.webp)

  @doc """
  Sanitizes and stores a LiveView-uploaded photo for the given owner.
  """
  @spec store_photo(String.t(), term(), Ecto.UUID.t()) ::
          {:ok, stored_photo()} | {:error, error_reason()}
  def store_photo(tmp_path, entry, owner_id) do
    with {:ok, bytes} <- read_file(tmp_path),
         {:ok, format} <- format_from_extension(entry.client_name),
         :ok <- validate_content_type(format, entry.client_type),
         {:ok, sanitized} <- sanitize(bytes, format),
         {:ok, metadata} <- write_sanitized_photo(sanitized, format, owner_id) do
      {:ok, metadata}
    end
  end

  @doc """
  Sanitizes image bytes for a known accepted image format.
  """
  @spec sanitize(binary(), image_format()) :: {:ok, binary()} | {:error, :invalid_image}
  def sanitize(bytes, :jpeg), do: sanitize_jpeg(bytes)
  def sanitize(bytes, :png), do: sanitize_png(bytes)
  def sanitize(bytes, :webp), do: sanitize_webp(bytes)

  @doc """
  Builds privacy-safe metadata for a stored image.
  """
  @spec build_metadata(Ecto.UUID.t() | String.t(), image_format(), Ecto.UUID.t() | String.t()) ::
          stored_photo()
  def build_metadata(owner_id, format, id) do
    extension = extension_for(format)
    stored_filename = "#{id}#{extension}"

    %{
      filename: "image#{extension}",
      stored_filename: stored_filename,
      content_type: content_type_for(format),
      path: "/uploads/#{owner_id}/#{stored_filename}"
    }
  end

  @doc """
  Returns true when the value contains common image metadata markers.
  """
  @spec contains_sensitive_metadata?(binary()) :: boolean()
  def contains_sensitive_metadata?(bytes) do
    Enum.any?(
      ["Exif", "http://ns.adobe.com/xap/1.0/", "XMP", "iTXt", "tEXt", "zTXt"],
      fn marker ->
        String.contains?(bytes, marker)
      end
    )
  end

  @spec read_file(String.t()) :: {:ok, binary()} | {:error, :read_failed}
  defp read_file(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> {:error, :read_failed}
    end
  end

  @spec write_sanitized_photo(binary(), image_format(), Ecto.UUID.t()) ::
          {:ok, stored_photo()} | {:error, :write_failed}
  defp write_sanitized_photo(bytes, format, owner_id) do
    metadata = build_metadata(owner_id, format, Ecto.UUID.generate())
    dir = Path.join(DiskPath.uploads_root(), to_string(owner_id))
    dest = Path.join(dir, metadata.stored_filename)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(dest, bytes) do
      {:ok, metadata}
    else
      {:error, _reason} -> {:error, :write_failed}
    end
  end

  @spec format_from_extension(String.t()) ::
          {:ok, image_format()} | {:error, :unsupported_extension}
  defp format_from_extension(client_name) do
    extension = client_name |> Path.extname() |> String.downcase()

    cond do
      extension in @jpeg_exts -> {:ok, :jpeg}
      extension in @png_exts -> {:ok, :png}
      extension in @webp_exts -> {:ok, :webp}
      true -> {:error, :unsupported_extension}
    end
  end

  @spec validate_content_type(image_format(), String.t()) ::
          :ok | {:error, :unsupported_content_type}
  defp validate_content_type(:jpeg, "image/jpeg"), do: :ok
  defp validate_content_type(:png, "image/png"), do: :ok
  defp validate_content_type(:webp, "image/webp"), do: :ok
  defp validate_content_type(_format, _content_type), do: {:error, :unsupported_content_type}

  @spec extension_for(image_format()) :: String.t()
  defp extension_for(:jpeg), do: ".jpg"
  defp extension_for(:png), do: ".png"
  defp extension_for(:webp), do: ".webp"

  @spec content_type_for(image_format()) :: String.t()
  defp content_type_for(:jpeg), do: "image/jpeg"
  defp content_type_for(:png), do: "image/png"
  defp content_type_for(:webp), do: "image/webp"

  @spec sanitize_jpeg(binary()) :: {:ok, binary()} | {:error, :invalid_image}
  defp sanitize_jpeg(<<0xFF, 0xD8, rest::binary>>) do
    parse_jpeg_segments(rest, <<0xFF, 0xD8>>)
  end

  defp sanitize_jpeg(_bytes), do: {:error, :invalid_image}

  @spec parse_jpeg_segments(binary(), binary()) :: {:ok, binary()} | {:error, :invalid_image}
  defp parse_jpeg_segments(<<0xFF, 0xDA, rest::binary>>, acc),
    do: {:ok, acc <> <<0xFF, 0xDA>> <> rest}

  defp parse_jpeg_segments(<<0xFF, 0xD9>>, acc), do: {:ok, acc <> <<0xFF, 0xD9>>}

  defp parse_jpeg_segments(<<0xFF, marker, rest::binary>>, acc)
       when marker in 0xD0..0xD7 do
    parse_jpeg_segments(rest, acc <> <<0xFF, marker>>)
  end

  defp parse_jpeg_segments(<<0xFF, marker, length::16, payload::binary>>, acc)
       when length >= 2 and byte_size(payload) >= length - 2 do
    segment_size = length - 2
    <<segment::binary-size(^segment_size), rest::binary>> = payload

    if jpeg_metadata_marker?(marker) do
      parse_jpeg_segments(rest, acc)
    else
      parse_jpeg_segments(rest, acc <> <<0xFF, marker, length::16>> <> segment)
    end
  end

  defp parse_jpeg_segments(_bytes, _acc), do: {:error, :invalid_image}

  @spec jpeg_metadata_marker?(0..255) :: boolean()
  defp jpeg_metadata_marker?(marker), do: marker in 0xE0..0xEF or marker == 0xFE

  @spec sanitize_png(binary()) :: {:ok, binary()} | {:error, :invalid_image}
  defp sanitize_png(<<137, 80, 78, 71, 13, 10, 26, 10, rest::binary>>) do
    parse_png_chunks(rest, <<137, 80, 78, 71, 13, 10, 26, 10>>)
  end

  defp sanitize_png(_bytes), do: {:error, :invalid_image}

  @spec parse_png_chunks(binary(), binary()) :: {:ok, binary()} | {:error, :invalid_image}
  defp parse_png_chunks(<<>>, _acc), do: {:error, :invalid_image}

  defp parse_png_chunks(
         <<length::32, type::binary-size(4), data::binary-size(length), crc::32, rest::binary>>,
         acc
       ) do
    chunk = <<length::32, type::binary-size(4), data::binary-size(length), crc::32>>

    cond do
      type == "IEND" and rest == "" ->
        {:ok, acc <> chunk}

      type == "IEND" ->
        {:error, :invalid_image}

      critical_png_chunk?(type) ->
        parse_png_chunks(rest, acc <> chunk)

      true ->
        parse_png_chunks(rest, acc)
    end
  end

  defp parse_png_chunks(_bytes, _acc), do: {:error, :invalid_image}

  @spec critical_png_chunk?(binary()) :: boolean()
  defp critical_png_chunk?(type), do: type in ["IHDR", "PLTE", "IDAT"]

  @spec sanitize_webp(binary()) :: {:ok, binary()} | {:error, :invalid_image}
  defp sanitize_webp(<<"RIFF", _size::32-little, "WEBP", chunks::binary>>) do
    with {:ok, sanitized_chunks} <- parse_webp_chunks(chunks, <<>>, false) do
      size = byte_size("WEBP" <> sanitized_chunks)
      {:ok, "RIFF" <> <<size::32-little>> <> "WEBP" <> sanitized_chunks}
    end
  end

  defp sanitize_webp(_bytes), do: {:error, :invalid_image}

  @spec parse_webp_chunks(binary(), binary(), boolean()) ::
          {:ok, binary()} | {:error, :invalid_image}
  defp parse_webp_chunks(<<>>, acc, true), do: {:ok, acc}
  defp parse_webp_chunks(<<>>, _acc, false), do: {:error, :invalid_image}

  defp parse_webp_chunks(
         <<type::binary-size(4), size::32-little, data::binary-size(size), rest::binary>>,
         acc,
         seen_payload?
       ) do
    padding =
      if rem(size, 2) == 1 do
        case rest do
          <<0, padded_rest::binary>> -> {<<0>>, padded_rest}
          _ -> :invalid
        end
      else
        {<<>>, rest}
      end

    case padding do
      :invalid ->
        {:error, :invalid_image}

      {pad, remaining} ->
        {chunk, payload?} = sanitized_webp_chunk(type, data, pad)
        parse_webp_chunks(remaining, acc <> chunk, seen_payload? or payload?)
    end
  end

  defp parse_webp_chunks(_bytes, _acc, _seen_payload?), do: {:error, :invalid_image}

  @spec sanitized_webp_chunk(binary(), binary(), binary()) :: {binary(), boolean()}
  defp sanitized_webp_chunk(type, _data, _pad) when type in ["EXIF", "XMP ", "ICCP"],
    do: {"", false}

  defp sanitized_webp_chunk("VP8X", <<flags, rest::binary>>, pad) do
    clean_flags = Bitwise.band(flags, 0b1100_0011)
    clean_data = <<clean_flags>> <> rest
    {webp_chunk("VP8X", clean_data, pad), true}
  end

  defp sanitized_webp_chunk(type, data, pad) do
    {webp_chunk(type, data, pad), webp_payload_chunk?(type)}
  end

  @spec webp_chunk(binary(), binary(), binary()) :: binary()
  defp webp_chunk(type, data, pad), do: type <> <<byte_size(data)::32-little>> <> data <> pad

  @spec webp_payload_chunk?(binary()) :: boolean()
  defp webp_payload_chunk?(type), do: type in ["VP8 ", "VP8L", "VP8X", "ANIM", "ANMF"]
end
