defmodule PlatserWeb.JoinRateLimiterTest do
  use ExUnit.Case, async: false

  alias PlatserWeb.JoinRateLimiter

  setup do
    JoinRateLimiter.reset_all()
    :ok
  end

  test "allows attempts until the fixed window limit is exceeded" do
    ip = {203, 0, 113, 10}

    assert :allow = JoinRateLimiter.allow?(ip, "abc123", 0, 2, 1_000)
    assert :allow = JoinRateLimiter.allow?(ip, "ABC123", 500, 2, 1_000)
    assert :throttle = JoinRateLimiter.allow?(ip, " abc123 ", 750, 2, 1_000)
  end

  test "allows attempts after the fixed window resets" do
    ip = {203, 0, 113, 11}

    assert :allow = JoinRateLimiter.allow?(ip, "ABC123", 0, 2, 1_000)
    assert :allow = JoinRateLimiter.allow?(ip, "ABC123", 500, 2, 1_000)
    assert :throttle = JoinRateLimiter.allow?(ip, "ABC123", 999, 2, 1_000)
    assert :allow = JoinRateLimiter.allow?(ip, "ABC123", 1_000, 2, 1_000)
  end

  test "keys attempts by remote IP and normalized code" do
    first_ip = {203, 0, 113, 12}
    second_ip = {203, 0, 113, 13}

    assert :allow = JoinRateLimiter.allow?(first_ip, "ABC123", 0, 1, 1_000)
    assert :throttle = JoinRateLimiter.allow?(first_ip, "abc123", 100, 1, 1_000)
    assert :allow = JoinRateLimiter.allow?(second_ip, "ABC123", 100, 1, 1_000)
    assert :allow = JoinRateLimiter.allow?(first_ip, "ZZZ999", 100, 1, 1_000)
  end
end
