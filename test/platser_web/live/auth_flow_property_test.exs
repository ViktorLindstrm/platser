defmodule PlatserWeb.AuthFlowPropertyTest do
  use PlatserWeb.ConnCase, async: false
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias Platser.Accounts.User

  require Ash.Query

  @password_min_length 8

  describe "registration form properties" do
    property "registration page exposes the fields required by the generated password action" do
      check all(_ <- StreamData.constant(:ok), max_runs: 1) do
        {:ok, view, _html} = live(build_conn(), ~p"/register")

        assert has_element?(view, "#user-password-register-with-password_email")
        assert has_element?(view, "#user-password-register-with-password_password")
        assert has_element?(view, "#user-password-register-with-password_password_confirmation")
        assert has_element?(view, "#user-password-register-with-password_display_name")
      end
    end

    property "valid registration inputs create a registered account through the web form" do
      check all(params <- registration_params_gen(), max_runs: 12) do
        {:ok, view, _html} = live(build_conn(), ~p"/register")

        render_submit(register_form(view), %{"user" => params})

        assert_sign_in_token_redirect(view)

        assert {:ok, user} = get_user_by_email(params["email"])
        assert user.display_name == params["display_name"]
        assert user.hashed_password
        refute user.is_guest
      end
    end

    property "mismatched password confirmation never creates an account" do
      check all(params <- mismatched_registration_params_gen(), max_runs: 12) do
        {:ok, view, _html} = live(build_conn(), ~p"/register")

        render_submit(register_form(view), %{"user" => params})

        refute_redirected(view)
        assert {:ok, nil} = get_user_by_email(params["email"])
      end
    end

    property "duplicate registration attempts do not create a second account" do
      check all(params <- registration_params_gen(), max_runs: 8) do
        user = create_user!(params)

        {:ok, view, _html} = live(build_conn(), ~p"/register")

        render_submit(register_form(view), %{"user" => params})

        refute_redirected(view)
        assert count_users_by_email(params["email"]) == 1
        assert {:ok, existing_user} = get_user_by_email(params["email"])
        assert existing_user.id == user.id
      end
    end
  end

  describe "sign-in form properties" do
    property "valid credentials submitted through the web form redirect into the authenticated area" do
      check all(params <- registration_params_gen(), max_runs: 10) do
        create_user!(params)

        {:ok, view, _html} = live(build_conn(), ~p"/sign-in")

        render_submit(sign_in_form(view), %{
          "user" => %{
            "email" => params["email"],
            "password" => params["password"]
          }
        })

        assert_sign_in_token_redirect(view)
      end
    end

    property "wrong passwords submitted through the web form do not authenticate" do
      check all({params, wrong_password} <- wrong_password_sign_in_gen(), max_runs: 10) do
        create_user!(params)

        {:ok, view, _html} = live(build_conn(), ~p"/sign-in")

        render_submit(sign_in_form(view), %{
          "user" => %{
            "email" => params["email"],
            "password" => wrong_password
          }
        })

        refute_redirected(view)
      end
    end

    property "anonymous users are redirected away from authenticated LiveViews" do
      check all(path <- authenticated_path_gen(), max_runs: 3) do
        assert {:error, {:redirect, %{to: "/sign-in"}}} = live(build_conn(), path)
      end
    end
  end

  defp assert_sign_in_token_redirect(view) do
    assert {to, _flash} = assert_redirect(view)
    assert String.starts_with?(to, "/auth/user/password/sign_in_with_token")
  end

  defp register_form(view) do
    element(view, "form[action$='/auth/user/password/register']")
  end

  defp sign_in_form(view) do
    element(view, "#user-password-sign-in-with-password")
  end

  defp create_user!(params) do
    Ash.create!(
      User,
      %{
        email: params["email"],
        display_name: params["display_name"],
        password: params["password"],
        password_confirmation: params["password_confirmation"]
      },
      action: :register,
      authorize?: false,
      context: %{strategy_name: :password}
    )
  end

  defp get_user_by_email(email) do
    User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one(authorize?: false)
  end

  defp count_users_by_email(email) do
    User
    |> Ash.Query.filter(email == ^email)
    |> Ash.count!(authorize?: false)
  end

  defp registration_params_gen do
    StreamData.bind(valid_email_gen(), fn email ->
      StreamData.bind(display_name_gen(), fn display_name ->
        StreamData.map(valid_password_gen(), fn password ->
          %{
            "email" => email,
            "display_name" => display_name,
            "password" => password,
            "password_confirmation" => password
          }
        end)
      end)
    end)
  end

  defp mismatched_registration_params_gen do
    StreamData.bind(registration_params_gen(), fn params ->
      StreamData.map(wrong_password_gen(params["password"]), fn password_confirmation ->
        %{params | "password_confirmation" => password_confirmation}
      end)
    end)
  end

  defp wrong_password_sign_in_gen do
    StreamData.bind(registration_params_gen(), fn params ->
      StreamData.map(wrong_password_gen(params["password"]), fn wrong_password ->
        {params, wrong_password}
      end)
    end)
  end

  defp valid_email_gen do
    StreamData.map(StreamData.string(:alphanumeric, min_length: 6, max_length: 24), fn local ->
      unique = System.unique_integer([:positive])
      normalized = local |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
      "auth_web_#{normalized}_#{unique}@example.com"
    end)
  end

  defp display_name_gen do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 40)
    |> StreamData.map(&("Auth User " <> &1))
  end

  defp valid_password_gen do
    StreamData.string(:alphanumeric, min_length: @password_min_length, max_length: 32)
  end

  defp wrong_password_gen(password) do
    valid_password_gen()
    |> StreamData.filter(&(&1 != password))
  end

  defp authenticated_path_gen do
    StreamData.member_of([~p"/events", ~p"/profile", ~p"/upgrade"])
  end
end
