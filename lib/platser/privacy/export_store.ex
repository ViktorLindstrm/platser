defmodule Platser.Privacy.ExportStore do
  alias Platser.Privacy.Export

  @type write_result ::
          {:ok, %{path: String.t(), size_bytes: non_neg_integer(), checksum: String.t()}}

  @spec root() :: String.t()
  def root do
    Application.get_env(:platser, :privacy_exports_root) ||
      Path.expand("priv/dsar_exports", File.cwd!())
  end

  @spec artifact_path(Ecto.UUID.t() | String.t()) :: String.t()
  def artifact_path(export_id) do
    Path.join(root(), "#{export_id}.json")
  end

  @spec path_for_export(Export.t()) :: String.t() | nil
  def path_for_export(%Export{id: id, path: path}) when is_binary(path) do
    expected = artifact_path(id)

    if Path.expand(path) == expected do
      expected
    else
      nil
    end
  end

  def path_for_export(%Export{}), do: nil

  @spec write_json(Ecto.UUID.t() | String.t(), map()) :: write_result() | {:error, term()}
  def write_json(export_id, payload) do
    path = artifact_path(export_id)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(payload, pretty: true),
         :ok <- File.write(path, json, [:binary]) do
      checksum = :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)
      {:ok, %{path: path, size_bytes: byte_size(json), checksum: checksum}}
    end
  end
end
