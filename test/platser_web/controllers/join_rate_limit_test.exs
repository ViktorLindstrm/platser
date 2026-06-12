defmodule PlatserWeb.JoinRateLimitTest do
  use PlatserWeb.ConnCase, async: false

  alias Platser.Accounts.User
  alias Platser.Events.Event
  alias PlatserWeb.JoinRateLimiter

  setup do
    JoinRateLimiter.reset_all()
    :ok
  end

  describe "GET /join/:code" do
    test "allows normal join page attempts", %{conn: conn} do
      event = create_event()

      conn =
        conn
        |> with_remote_ip({203, 0, 113, 20})
        |> get(~p"/join/#{event.join_code}")

      assert html_response(conn, 200) =~ "guest-join-form"
    end

    test "throttles repeated attempts with a uniform response", %{conn: conn} do
      event = create_event()
      remote_ip = {203, 0, 113, 21}
      invalid_remote_ip = {203, 0, 113, 24}
      throttle_body = "Too many invite attempts. Please try again later."

      for _ <- 1..5 do
        conn
        |> recycle()
        |> with_remote_ip(remote_ip)
        |> get(~p"/join/#{String.downcase(event.join_code)}")
        |> html_response(200)
      end

      valid_conn =
        conn
        |> recycle()
        |> with_remote_ip(remote_ip)
        |> get(~p"/join/#{event.join_code}")

      for _ <- 1..5 do
        conn
        |> recycle()
        |> with_remote_ip(invalid_remote_ip)
        |> get(~p"/join/NOPE12")
        |> html_response(200)
      end

      invalid_conn =
        conn
        |> recycle()
        |> with_remote_ip(invalid_remote_ip)
        |> get(~p"/join/NOPE12")

      assert response(valid_conn, 429) == throttle_body
      assert response(invalid_conn, 429) == throttle_body
    end
  end

  describe "POST /guest-join/:code" do
    test "preserves the normal guest join flow", %{conn: conn} do
      event = create_event()

      conn =
        conn
        |> with_remote_ip({203, 0, 113, 22})
        |> post(~p"/guest-join/#{event.join_code}", %{"display_name" => "Guest Person"})

      assert redirected_to(conn) == ~p"/events/#{event.id}/map"
    end

    test "throttles repeated guest join attempts", %{conn: conn} do
      remote_ip = {203, 0, 113, 23}

      for _ <- 1..5 do
        result =
          conn
          |> recycle()
          |> with_remote_ip(remote_ip)
          |> post(~p"/guest-join/bad123", %{"display_name" => "Guest Person"})

        assert redirected_to(result) == ~p"/join/bad123"
      end

      throttled_conn =
        conn
        |> recycle()
        |> with_remote_ip(remote_ip)
        |> post(~p"/guest-join/BAD123", %{"display_name" => "Guest Person"})

      assert response(throttled_conn, 429) == "Too many invite attempts. Please try again later."
    end
  end

  @spec with_remote_ip(Plug.Conn.t(), :inet.ip_address()) :: Plug.Conn.t()
  defp with_remote_ip(conn, remote_ip) do
    %{conn | remote_ip: remote_ip}
  end

  @spec create_event() :: Event.t()
  defp create_event do
    admin = create_user()

    {:ok, event} =
      Ash.create(
        Event,
        %{
          name: "Join Rate Limit Test",
          description: "A throttled event",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: admin
      )

    event
  end

  @spec create_user() :: User.t()
  defp create_user do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "join_rate_limit_#{n}@example.com",
          display_name: "Join Rate Limit #{n}",
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end
end
