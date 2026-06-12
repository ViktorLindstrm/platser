defmodule Platser.Privacy.ExportBuilder do
  import Ecto.Query

  alias Platser.Privacy.Export
  alias Platser.Privacy.ExportStore
  alias Platser.Repo

  @type section_name ::
          :account
          | :auth_tokens
          | :memberships
          | :member_events
          | :created_pois
          | :created_geofences
          | :activity_entries
          | :media_attachments

  @type export_payload :: %{
          format_version: String.t(),
          generated_at: String.t(),
          subject_user_id: String.t(),
          retention: map(),
          inventory: [map()],
          data: map()
        }

  @spec build(Ecto.UUID.t() | String.t()) :: :ok
  def build(export_id) do
    export = Ash.get!(Export, export_id, authorize?: false)
    {:ok, export} = Ash.update(export, %{}, action: :start_processing, authorize?: false)

    case build_payload(export.user_id) do
      {:ok, payload} ->
        complete_export(export, payload)

      {:error, reason} ->
        fail_export(export, reason)
    end
  rescue
    exception ->
      export = Ash.get!(Export, export_id, authorize?: false)
      fail_export(export, Exception.message(exception))
  end

  @spec build_payload(Ecto.UUID.t() | String.t()) :: {:ok, export_payload()} | {:error, term()}
  def build_payload(user_id) do
    account = one_user(user_id)

    if is_nil(account) do
      {:error, :user_not_found}
    else
      data = %{
        account: account,
        auth_tokens: auth_tokens(user_id),
        memberships: memberships(user_id),
        member_events: member_events(user_id),
        created_pois: created_pois(user_id),
        created_geofences: created_geofences(user_id),
        activity_entries: activity_entries(user_id),
        media_attachments: media_attachments(user_id)
      }

      {:ok,
       %{
         format_version: "platser-dsar-v1",
         generated_at: DateTime.utc_now(:second) |> DateTime.to_iso8601(),
         subject_user_id: encode_id(user_id),
         retention: %{expires_after_days: 7},
         inventory: inventory(data),
         data: data
       }}
    end
  end

  @spec complete_export(Export.t(), export_payload()) :: :ok
  defp complete_export(export, payload) do
    case ExportStore.write_json(
           export.id,
           put_in(payload.retention[:expires_at], iso(export.expires_at))
         ) do
      {:ok, metadata} ->
        {:ok, _export} = Ash.update(export, metadata, action: :complete, authorize?: false)
        :ok

      {:error, reason} ->
        fail_export(export, reason)
    end
  end

  @spec fail_export(Export.t(), term()) :: :ok
  defp fail_export(export, reason) do
    _ =
      Ash.update(export, %{failure_reason: inspect(reason)},
        action: :fail,
        authorize?: false
      )

    :ok
  end

  @spec inventory(map()) :: [map()]
  defp inventory(data) do
    [
      inventory_row(:account, "users", data.account),
      inventory_row(:auth_tokens, "tokens", data.auth_tokens),
      inventory_row(:memberships, "memberships", data.memberships),
      inventory_row(:member_events, "events", data.member_events),
      inventory_row(:created_pois, "pois", data.created_pois),
      inventory_row(:created_geofences, "geofences", data.created_geofences),
      inventory_row(:activity_entries, "entries", data.activity_entries),
      inventory_row(:media_attachments, "media_attachments", data.media_attachments)
    ]
  end

  @spec inventory_row(section_name(), String.t(), map() | [map()] | nil) :: map()
  defp inventory_row(section, source_table, nil) do
    %{section: section, source_table: source_table, record_count: 0}
  end

  defp inventory_row(section, source_table, records) when is_list(records) do
    %{section: section, source_table: source_table, record_count: length(records)}
  end

  defp inventory_row(section, source_table, _record) do
    %{section: section, source_table: source_table, record_count: 1}
  end

  @spec one_user(Ecto.UUID.t() | String.t()) :: map() | nil
  defp one_user(user_id) do
    "users"
    |> where([u], u.id == type(^user_id, :binary_id))
    |> select([u], %{
      id: u.id,
      email: u.email,
      display_name: u.display_name,
      is_simulated: u.is_simulated,
      is_guest: u.is_guest
    })
    |> Repo.one()
    |> normalize_record()
  end

  @spec auth_tokens(Ecto.UUID.t() | String.t()) :: [map()]
  defp auth_tokens(user_id) do
    subject_suffix = encode_id(user_id)

    "tokens"
    |> where([t], like(t.subject, ^"%#{subject_suffix}"))
    |> order_by([t], asc: t.created_at)
    |> select([t], %{
      purpose: t.purpose,
      expires_at: t.expires_at,
      created_at: t.created_at,
      updated_at: t.updated_at,
      extra_data: t.extra_data
    })
    |> Repo.all()
    |> normalize_records()
  end

  @spec memberships(Ecto.UUID.t() | String.t()) :: [map()]
  defp memberships(user_id) do
    "memberships"
    |> where([m], m.user_id == type(^user_id, :binary_id))
    |> order_by([m], asc: m.joined_at)
    |> select([m], %{
      id: m.id,
      event_id: m.event_id,
      user_id: m.user_id,
      role: m.role,
      joined_at: m.joined_at
    })
    |> Repo.all()
    |> normalize_records()
  end

  @spec member_events(Ecto.UUID.t() | String.t()) :: [map()]
  defp member_events(user_id) do
    "events"
    |> join(:inner, [e], m in "memberships", on: m.event_id == e.id)
    |> where([_e, m], m.user_id == type(^user_id, :binary_id))
    |> order_by([e, _m], asc: e.starts_at)
    |> select([e, _m], %{
      id: e.id,
      name: e.name,
      description: e.description,
      starts_at: e.starts_at,
      ends_at: e.ends_at,
      creator_id: e.creator_id,
      inserted_at: e.inserted_at,
      allow_public_comments: e.allow_public_comments,
      join_code_rotated_at: e.join_code_rotated_at,
      join_code_expires_at: e.join_code_expires_at,
      join_code_invalidated_at: e.join_code_invalidated_at,
      bounds: e.bounds
    })
    |> Repo.all()
    |> normalize_records()
  end

  @spec created_pois(Ecto.UUID.t() | String.t()) :: [map()]
  defp created_pois(user_id) do
    "pois"
    |> where([p], p.creator_id == type(^user_id, :binary_id))
    |> order_by([p], asc: p.id)
    |> select([p], %{
      id: p.id,
      event_id: p.event_id,
      creator_id: p.creator_id,
      name: p.name,
      description: p.description,
      comment: p.comment,
      color: p.color,
      category: p.category,
      visibility: p.visibility,
      published_at: p.published_at,
      location: p.location
    })
    |> Repo.all()
    |> normalize_records()
  end

  @spec created_geofences(Ecto.UUID.t() | String.t()) :: [map()]
  defp created_geofences(user_id) do
    "geofences"
    |> where([g], g.creator_id == type(^user_id, :binary_id))
    |> order_by([g], asc: g.id)
    |> select([g], %{
      id: g.id,
      event_id: g.event_id,
      creator_id: g.creator_id,
      name: g.name,
      description: g.description,
      comment: g.comment,
      purpose: g.purpose,
      visibility: g.visibility,
      color: g.color,
      published_at: g.published_at,
      geometry: g.geometry
    })
    |> Repo.all()
    |> normalize_records()
  end

  @spec activity_entries(Ecto.UUID.t() | String.t()) :: [map()]
  defp activity_entries(user_id) do
    "entries"
    |> where(
      [e],
      e.actor_id == type(^user_id, :binary_id) or
        (e.subject_type == "user" and e.subject_id == type(^user_id, :binary_id))
    )
    |> order_by([e], asc: e.inserted_at)
    |> select([e], %{
      id: e.id,
      event_id: e.event_id,
      actor_id: e.actor_id,
      action: e.action,
      subject_type: e.subject_type,
      subject_id: e.subject_id,
      message: e.message,
      lat: e.lat,
      lng: e.lng,
      inserted_at: e.inserted_at
    })
    |> Repo.all()
    |> normalize_records()
  end

  @spec media_attachments(Ecto.UUID.t() | String.t()) :: [map()]
  defp media_attachments(user_id) do
    "media_attachments"
    |> where([a], a.uploader_id == type(^user_id, :binary_id))
    |> order_by([a], asc: a.inserted_at)
    |> select([a], %{
      id: a.id,
      poi_id: a.poi_id,
      geofence_id: a.geofence_id,
      uploader_id: a.uploader_id,
      filename: a.filename,
      stored_filename: a.stored_filename,
      content_type: a.content_type,
      path: a.path,
      inserted_at: a.inserted_at
    })
    |> Repo.all()
    |> normalize_records()
  end

  @spec normalize_records([map()]) :: [map()]
  defp normalize_records(records), do: Enum.map(records, &normalize_record/1)

  @spec normalize_record(map() | nil) :: map() | nil
  defp normalize_record(nil), do: nil

  defp normalize_record(record) do
    Map.new(record, fn {key, value} -> {key, normalize_value(value)} end)
  end

  @spec normalize_value(term()) :: term()
  defp normalize_value(nil), do: nil
  defp normalize_value(value) when is_boolean(value), do: value
  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp normalize_value(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp normalize_value(value) when is_binary(value) do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> value
    end
  end

  defp normalize_value(%Postgrex.INET{} = value), do: inspect(value)
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value), do: value

  @spec encode_id(Ecto.UUID.t() | binary()) :: String.t()
  defp encode_id(<<_::128>> = id), do: Ecto.UUID.load!(id)
  defp encode_id(id) when is_binary(id), do: id

  @spec iso(DateTime.t() | nil) :: String.t() | nil
  defp iso(nil), do: nil
  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
