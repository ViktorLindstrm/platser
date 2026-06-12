defmodule PlatserWeb.ProfileExportFlowPropertyTest do
  use PlatserWeb.ConnCase, async: false
  use ExUnitProperties

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platser.Accounts.User
  alias Platser.Privacy.Export
  alias Platser.Privacy.ExportStore
  alias Platser.Repo

  setup do
    previous_root = Application.get_env(:platser, :privacy_exports_root)
    previous_async = Application.get_env(:platser, :privacy_exports_async?)
    root = Path.join(System.tmp_dir!(), "platser-dsar-test-#{System.unique_integer([:positive])}")
    Application.put_env(:platser, :privacy_exports_root, root)
    Application.put_env(:platser, :privacy_exports_async?, false)

    on_exit(fn ->
      if is_nil(previous_root) do
        Application.delete_env(:platser, :privacy_exports_root)
      else
        Application.put_env(:platser, :privacy_exports_root, previous_root)
      end

      if is_nil(previous_async) do
        Application.delete_env(:platser, :privacy_exports_async?)
      else
        Application.put_env(:platser, :privacy_exports_async?, previous_async)
      end

      File.rm_rf(root)
    end)

    :ok
  end

  property "profile UI can request an export and shows request status" do
    check all(
            display_name <- StreamData.string(:alphanumeric, min_length: 3, max_length: 16),
            max_runs: 3
          ) do
      user = create_user(display_name)
      conn = sign_in_conn(build_conn(), user)

      {:ok, view, _html} = live(conn, ~p"/profile")

      assert has_element?(view, "#privacy-export-panel")
      assert has_element?(view, "#request-account-export")

      view
      |> element("#request-account-export")
      |> render_click()

      assert {:ok, exports} = Platser.Privacy.list_account_exports(actor: user)
      assert [_export | _] = exports
      assert has_element?(view, "#privacy-export-list")
    end
  end

  property "download route enforces owner authorization and artifact availability states" do
    check all(state <- StreamData.member_of([:pending, :available, :expired]), max_runs: 3) do
      owner = create_user("download_owner")
      other = create_user("download_other")
      export = create_export(owner)

      export =
        case state do
          :pending ->
            export

          :available ->
            complete_export(export, %{status: "available"})

          :expired ->
            export
            |> complete_export(%{status: "expired"})
            |> expire_export()
        end

      denied_conn =
        build_conn()
        |> sign_in_conn(other)
        |> get(~p"/privacy/exports/#{export.id}/download")

      assert denied_conn.status in [403, 404]

      owner_conn =
        build_conn()
        |> sign_in_conn(owner)
        |> get(~p"/privacy/exports/#{export.id}/download")

      case state do
        :pending -> assert owner_conn.status == 404
        :available -> assert owner_conn.status == 200
        :expired -> assert owner_conn.status == 410
      end
    end
  end

  property "profile deletion flow requires confirmation and revokes post-delete access" do
    check all(
            display_name <- StreamData.string(:alphanumeric, min_length: 3, max_length: 16),
            max_runs: 3
          ) do
      user = create_user("delete_#{display_name}")
      conn = sign_in_conn(build_conn(), user)

      {:ok, view, _html} = live(conn, ~p"/profile")

      assert has_element?(view, "#account-deletion-panel")
      assert has_element?(view, "#account-deletion-form")
      assert has_element?(view, "#delete-account-cancel")

      view
      |> form("#account-deletion-form", delete: %{confirmation: "cancel"})
      |> render_submit()

      refute Ash.get!(User, user.id, authorize?: false).deleted_at

      assert {:error, {:redirect, %{to: "/sign-out"}}} =
               view
               |> form("#account-deletion-form", delete: %{confirmation: "DELETE"})
               |> render_submit()

      deleted_user = Ash.get!(User, user.id, authorize?: false)
      assert %DateTime{} = deleted_user.deleted_at
      assert deleted_user.display_name == "Deleted user"

      denied_conn = get(conn, ~p"/profile")
      assert redirected_to(denied_conn) =~ "/sign-in"
    end
  end

  @spec create_user(String.t()) :: User.t()
  defp create_user(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "profile_export_#{tag}_#{n}@example.com",
          display_name: "Profile Export #{tag} #{n}",
          password: "password123",
          password_confirmation: "password123"
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
        %{"email" => user.email, "password" => "password123"}
      )

    signed_in_conn =
      conn
      |> init_test_session(%{})
      |> PlatserWeb.AuthController.success(%{}, signed_in_user, signed_in_user.__metadata__.token)

    conn
    |> recycle()
    |> init_test_session(Map.get(signed_in_conn.private, :plug_session, %{}))
  end

  @spec create_export(User.t()) :: Export.t()
  defp create_export(user) do
    {:ok, export} =
      Export
      |> Ash.Changeset.for_create(:request, %{}, actor: user)
      |> Ash.create()

    export
  end

  @spec complete_export(Export.t(), map()) :: Export.t()
  defp complete_export(export, payload) do
    {:ok, metadata} = ExportStore.write_json(export.id, payload)
    {:ok, export} = Ash.update(export, metadata, action: :complete, authorize?: false)
    export
  end

  @spec expire_export(Export.t()) :: Export.t()
  defp expire_export(export) do
    expired_at = DateTime.utc_now(:second) |> DateTime.add(-60, :second)

    {1, _} =
      Repo.update_all(
        from(e in "privacy_exports", where: e.id == type(^export.id, :binary_id)),
        set: [expires_at: expired_at]
      )

    Ash.get!(Export, export.id, authorize?: false)
  end
end
