defmodule PlatserWeb.MediaControllerTest do
  use PlatserWeb.ConnCase, async: false

  alias Platser.Accounts.User
  alias Platser.Events
  alias Platser.Map, as: PlatserMap
  alias Platser.Media
  alias Platser.Media.DiskPath

  @password "password123"
  @content "authorized upload bytes"

  describe "GET /uploads/*path" do
    test "rejects unauthenticated direct upload access", %{conn: conn} do
      %{attachment: attachment} = create_uploaded_attachment("anonymous")

      conn = get(conn, attachment.path)

      assert response(conn, 403) == "Forbidden"
    end

    test "rejects authenticated users who are not members of the owning event", %{conn: conn} do
      %{attachment: attachment} = create_uploaded_attachment("unrelated")
      unrelated_user = create_user("unrelated_user")

      conn =
        conn
        |> sign_in_conn(unrelated_user)
        |> get(attachment.path)

      assert response(conn, 404) == "Not Found"
    end

    test "serves uploaded bytes to authorized event members", %{conn: conn} do
      %{event: event, attachment: attachment} = create_uploaded_attachment("member")
      member = create_user("member_user")
      join_event(event, member)

      conn =
        conn
        |> sign_in_conn(member)
        |> get(attachment.path)

      assert response(conn, 200) == @content
      assert get_resp_header(conn, "content-type") == ["image/jpeg; charset=utf-8"]
      assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]

      assert get_resp_header(conn, "content-disposition") == [
               ~s(inline; filename="#{attachment.stored_filename}")
             ]
    end

    test "returns not found when authorized metadata exists but the file is missing", %{
      conn: conn
    } do
      %{event: event, attachment: attachment} =
        create_uploaded_attachment("missing", write_file?: false)

      member = create_user("missing_member")
      join_event(event, member)

      conn =
        conn
        |> sign_in_conn(member)
        |> get(attachment.path)

      assert response(conn, 404) == "Not Found"
    end

    test "returns not found for traversal-shaped routed URL input", %{conn: conn} do
      %{event: event, poi: poi} = create_uploaded_attachment("traversal")
      member = create_user("traversal_member")
      join_event(event, member)

      conn =
        conn
        |> sign_in_conn(member)
        |> get("/uploads/#{poi.id}/..%2Fsecret.jpg")

      assert response(conn, 404) == "Not Found"
    end
  end

  @spec create_uploaded_attachment(String.t(), keyword()) :: %{
          event: Platser.Events.Event.t(),
          poi: Platser.Map.Poi.t(),
          attachment: Platser.Media.Attachment.t()
        }
  defp create_uploaded_attachment(tag, opts \\ []) do
    user = create_user("#{tag}_owner")
    event = create_event(user)
    poi = create_poi(user, event)
    stored_filename = "#{Ecto.UUID.generate()}.jpg"

    {:ok, attachment} =
      Media.create_attachment(
        %{
          filename: "image.jpg",
          stored_filename: stored_filename,
          content_type: "image/jpeg",
          path: "/uploads/#{poi.id}/#{stored_filename}",
          poi_id: poi.id
        },
        actor: user
      )

    if Keyword.get(opts, :write_file?, true) do
      write_attachment_file(attachment)
    end

    %{event: event, poi: poi, attachment: attachment}
  end

  @spec create_user(String.t()) :: User.t()
  defp create_user(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "#{tag}_#{n}@example.com",
          display_name: "Upload #{tag} #{n}",
          password: @password,
          password_confirmation: @password
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end

  @spec sign_in_conn(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  defp sign_in_conn(conn, user) do
    {:ok, signed_in_user} =
      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(User, :password),
        :sign_in,
        %{email: user.email, password: @password},
        authorize?: false
      )

    signed_in_conn =
      conn
      |> put_private(:phoenix_endpoint, PlatserWeb.Endpoint)
      |> init_test_session(%{})
      |> PlatserWeb.AuthController.success(%{}, signed_in_user, signed_in_user.__metadata__.token)

    Phoenix.ConnTest.build_conn()
    |> put_private(:phoenix_endpoint, PlatserWeb.Endpoint)
    |> init_test_session(Map.get(signed_in_conn.private, :plug_session, %{}))
  end

  @spec create_event(User.t()) :: Platser.Events.Event.t()
  defp create_event(user) do
    {:ok, event} =
      Events.create_event(
        %{
          name: "Upload Delivery #{System.unique_integer([:positive])}",
          description: "Request authorization coverage",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: user
      )

    event
  end

  @spec join_event(Platser.Events.Event.t(), User.t()) :: Platser.Events.Membership.t()
  defp join_event(event, user) do
    {:ok, membership} = Events.join_event(event.join_code, actor: user)
    membership
  end

  @spec create_poi(User.t(), Platser.Events.Event.t()) :: Platser.Map.Poi.t()
  defp create_poi(user, event) do
    {:ok, poi} =
      PlatserMap.create_poi(
        %{
          name: "Upload POI",
          description: "POI with protected media",
          category: :viewpoint,
          location: %Geo.Point{coordinates: {18.0686, 59.3293}, srid: 4326},
          event_id: event.id
        },
        actor: user
      )

    poi
  end

  @spec write_attachment_file(Platser.Media.Attachment.t()) :: :ok
  defp write_attachment_file(attachment) do
    path = DiskPath.for_attachment(attachment)

    on_exit(fn ->
      attachment
      |> DiskPath.for_attachment()
      |> Path.dirname()
      |> File.rm_rf()
    end)

    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, @content)
  end
end
