# frozen_string_literal: true

require_relative "../test_helper"
require "ipaddr"

class ClientIPTest < Minitest::Test
  def teardown
    Izen::ClientIP.reset!
    ENV.delete("TRUSTED_PROXIES")
    ENV.delete("TRUST_CLOUDFLARE")
  end

  def test_returns_the_peer_when_it_is_not_a_trusted_proxy
    env = { "REMOTE_ADDR" => "203.0.113.7", "HTTP_X_FORWARDED_FOR" => "1.2.3.4" }

    assert_equal "203.0.113.7", Izen::ClientIP.call(env)
  end

  def test_ignores_a_forged_forwarded_header_from_a_public_peer
    env = { "REMOTE_ADDR" => "198.51.100.9", "HTTP_X_FORWARDED_FOR" => "10.0.0.1, 203.0.113.5" }

    assert_equal "198.51.100.9", Izen::ClientIP.call(env)
  end

  def test_walks_forwarded_for_behind_a_trusted_proxy
    env = { "REMOTE_ADDR" => "172.18.0.5", "HTTP_X_FORWARDED_FOR" => "203.0.113.9, 172.18.0.5" }

    assert_equal "203.0.113.9", Izen::ClientIP.call(env)
  end

  def test_returns_the_rightmost_untrusted_hop
    env = { "REMOTE_ADDR" => "10.0.0.1", "HTTP_X_FORWARDED_FOR" => "203.0.113.9, 198.51.100.1, 10.0.0.1" }

    assert_equal "198.51.100.1", Izen::ClientIP.call(env)
  end

  def test_uses_cf_connecting_ip_when_cloudflare_is_trusted
    Izen::ClientIP.trust_cloudflare = true
    env                             = {
      "REMOTE_ADDR"           => "104.16.0.1",
      "HTTP_CF_CONNECTING_IP" => "203.0.113.9",
      "HTTP_X_FORWARDED_FOR"  => "203.0.113.9, 104.16.0.1"
    }

    assert_equal "203.0.113.9", Izen::ClientIP.call(env)
  end

  def test_ignores_cf_connecting_ip_without_trust
    env = { "REMOTE_ADDR" => "104.16.0.1", "HTTP_CF_CONNECTING_IP" => "203.0.113.9" }

    assert_equal "104.16.0.1", Izen::ClientIP.call(env)
  end

  def test_honors_cf_connecting_ip_when_the_peer_is_a_trusted_proxy
    Izen::ClientIP.trusted_proxies = [ IPAddr.new("104.16.0.0/12") ]
    env                            = { "REMOTE_ADDR" => "104.16.0.1", "HTTP_CF_CONNECTING_IP" => "203.0.113.9" }

    assert_equal "203.0.113.9", Izen::ClientIP.call(env)
  end

  def test_trusted_proxies_can_come_from_the_environment
    ENV["TRUSTED_PROXIES"] = "198.51.100.0/24"
    env                    = { "REMOTE_ADDR"          => "198.51.100.10",
                               "HTTP_X_FORWARDED_FOR" => "203.0.113.9, 198.51.100.10" }

    assert_equal "203.0.113.9", Izen::ClientIP.call(env)
  end

  def test_parses_the_standard_forwarded_header
    env = { "REMOTE_ADDR" => "10.0.0.1", "HTTP_FORWARDED" => "for=203.0.113.9;proto=https, for=10.0.0.1" }

    assert_equal "203.0.113.9", Izen::ClientIP.call(env)
  end

  def test_trusted_handles_invalid_addresses
    refute Izen::ClientIP.trusted?("not-an-ip")
    assert Izen::ClientIP.trusted?("127.0.0.1")
  end
end
