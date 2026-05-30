defmodule PlatserWeb.Events.IndexLiveTest do
  use PlatserWeb.ConnCase, async: false
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias Platser.Accounts.User

  defp create_user(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "#{tag}_#{n}@example.com",
          display_name: String.capitalize("#{tag} #{n}"),
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    {:ok, signed_in_user} =
      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(User, :password),
        :sign_in,
        %{email: user.email, password: "password123"},
        authorize?: false
      )

    signed_in_user
  end

  defp sign_in_conn(conn, user) do
    signed_in_conn =
      conn
      |> put_private(:phoenix_endpoint, PlatserWeb.Endpoint)
      |> init_test_session(%{})
      |> PlatserWeb.AuthController.success(%{}, user, user.__metadata__.token)

    Phoenix.ConnTest.build_conn()
    |> put_private(:phoenix_endpoint, PlatserWeb.Endpoint)
    |> init_test_session(Map.get(signed_in_conn.private, :plug_session, %{}))
  end

  describe "events index page" do
    test "displays join event form", %{conn: conn} do
      user = create_user("user")
      conn = sign_in_conn(conn, user)

      {:ok, view, _html} = live(conn, ~p"/events")

      assert has_element?(view, "#join-code-input")
      assert has_element?(view, "#join-code-btn")
    end

    test "join button is disabled when form is empty", %{conn: conn} do
      user = create_user("user")
      conn = sign_in_conn(conn, user)

      {:ok, view, _html} = live(conn, ~p"/events")

      join_btn = element(view, "#join-code-btn")
      assert join_btn |> render() =~ "disabled"
    end

    test "join button becomes enabled when valid code is entered", %{conn: conn} do
      user = create_user("user")
      conn = sign_in_conn(conn, user)

      {:ok, view, _html} = live(conn, ~p"/events")

      render_change(view, "validate_join_code", %{"code" => "AX7K2P"})

      join_btn = element(view, "#join-code-btn")
      refute join_btn |> render() =~ "disabled"
    end

    test "join button is disabled when code is less than 6 characters", %{conn: conn} do
      user = create_user("user")
      conn = sign_in_conn(conn, user)

      {:ok, view, _html} = live(conn, ~p"/events")

      render_change(view, "validate_join_code", %{"code" => "AX7K2"})

      join_btn = element(view, "#join-code-btn")
      assert join_btn |> render() =~ "disabled"
    end

    test "join button is disabled when code contains invalid characters", %{conn: conn} do
      user = create_user("user")
      conn = sign_in_conn(conn, user)

      {:ok, view, _html} = live(conn, ~p"/events")

      render_change(view, "validate_join_code", %{"code" => "AX7K2!"})

      join_btn = element(view, "#join-code-btn")
      assert join_btn |> render() =~ "disabled"
    end

    test "submitting join form with valid code navigates to /join/:code", %{conn: conn} do
      user = create_user("user")
      conn = sign_in_conn(conn, user)

      {:ok, view, _html} = live(conn, ~p"/events")

      render_change(view, "validate_join_code", %{"code" => "ax7k2p"})
      render_submit(view, "join_by_code", %{"code" => "ax7k2p"})

      assert_redirect(view, ~p"/join/AX7K2P")
    end
  end

  describe "join code validation property tests" do
    property "code of exactly 6 alphanumeric characters enables submit" do
      check all(code <- alphanumeric_code(6)) do
        user = create_user("user")
        conn = sign_in_conn(build_conn(), user)

        {:ok, view, _html} = live(conn, ~p"/events")

        render_change(view, "validate_join_code", %{"code" => code})

        join_btn = element(view, "#join-code-btn")
        refute render(join_btn) =~ "disabled"
      end
    end

    property "code submitted navigates to /join/:code uppercased" do
      check all(code <- alphanumeric_code(6)) do
        user = create_user("user")
        conn = sign_in_conn(build_conn(), user)

        {:ok, view, _html} = live(conn, ~p"/events")

        render_change(view, "validate_join_code", %{"code" => code})
        render_submit(view, "join_by_code", %{"code" => code})

        assert_redirect(view, ~p"/join/#{String.upcase(code)}")
      end
    end

    property "code shorter than 6 characters keeps submit disabled" do
      check all(code <- alphanumeric_code_with_max_length(5)) do
        user = create_user("user")
        conn = sign_in_conn(build_conn(), user)

        {:ok, view, _html} = live(conn, ~p"/events")

        render_change(view, "validate_join_code", %{"code" => code})

        join_btn = element(view, "#join-code-btn")
        assert render(join_btn) =~ "disabled"
      end
    end

    property "code longer than 6 characters keeps submit disabled" do
      check all(code <- alphanumeric_code_with_min_length(7)) do
        user = create_user("user")
        conn = sign_in_conn(build_conn(), user)

        {:ok, view, _html} = live(conn, ~p"/events")

        short_code = String.slice(code, 0..5)
        render_change(view, "validate_join_code", %{"code" => short_code})

        join_btn = element(view, "#join-code-btn")
        refute render(join_btn) =~ "disabled"
      end
    end
  end

  defp alphanumeric_code(length) do
    StreamData.string(:alphanumeric, length: length)
  end

  defp alphanumeric_code_with_max_length(max_length) do
    StreamData.string(:alphanumeric, length: 0..max_length)
    |> StreamData.filter(&(String.length(&1) < 6))
  end

  defp alphanumeric_code_with_min_length(min_length) do
    StreamData.string(:alphanumeric, length: min_length..20)
  end
end
