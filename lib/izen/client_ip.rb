# frozen_string_literal: true

require "ipaddr"
require "rack/request"

module Izen
  # Resolves the real client IP when the app sits behind a reverse proxy
  # (Kamal's proxy, Cloudflare, an ingress, ...).
  #
  # `Rack::Request#ip` already walks `Forwarded` / `X-Forwarded-For` when the
  # immediate peer (`REMOTE_ADDR`) is a trusted proxy, but it stops at the first
  # *public* proxy address — which is exactly what Cloudflare's edge is. So
  # behind Cloudflare it returns the Cloudflare IP, not the visitor. Cloudflare
  # sets `CF-Connecting-IP` to the visitor address and overwrites any value a
  # client sends, so that header is the reliable source once you trust the edge.
  #
  #   Izen::ClientIP.call(request.env)
  #
  # Resolution order:
  #
  #   1. `CF-Connecting-IP` when Cloudflare is trusted (`TRUST_CLOUDFLARE=1`) or
  #      the peer is in `trusted_proxies`;
  #   2. the rightmost non-trusted address in `Forwarded`/`X-Forwarded-For` when
  #      the peer is a trusted proxy;
  #   3. the peer address.
  #
  # Trusted proxies default to loopback and the private ranges (so a directly
  # reachable app ignores a forged `X-Forwarded-For`); extend or replace them
  # with the comma-separated `TRUSTED_PROXIES` env var (CIDRs).
  #
  # Only set `TRUST_CLOUDFLARE=1` when the origin is reachable *only* through
  # Cloudflare (firewall it to Cloudflare's IP ranges); otherwise a direct
  # client could forge `CF-Connecting-IP`.
  module ClientIP
    CLOUDFLARE_HEADER = "HTTP_CF_CONNECTING_IP"

    DEFAULT_TRUSTED_PROXIES = %w[
      127.0.0.0/8
      ::1/128
      10.0.0.0/8
      172.16.0.0/12
      192.168.0.0/16
      fc00::/7
    ].freeze

    class << self
      def trusted_proxies
        @trusted_proxies ||= parse(ENV["TRUSTED_PROXIES"]) || DEFAULT_TRUSTED_PROXIES.map { |cidr| IPAddr.new(cidr) }
      end

      attr_writer :trusted_proxies

      def trust_cloudflare?
        return @trust_cloudflare unless @trust_cloudflare.nil?

        ENV["TRUST_CLOUDFLARE"] == "1"
      end

      attr_writer :trust_cloudflare

      def call(env)
        peer = presence(env["REMOTE_ADDR"]).to_s

        if (trust_cloudflare? || trusted?(peer)) && (cloudflare = presence(env[CLOUDFLARE_HEADER]))
          return cloudflare
        end

        return peer unless trusted?(peer)

        forwarded = Array(Rack::Request.new(env).forwarded_for)
        forwarded.reverse_each { |ip| return ip unless trusted?(ip) }
        forwarded.first || peer
      end

      # Whether +ip+ falls in the trusted-proxy ranges.
      def trusted?(ip)
        address = IPAddr.new(ip.to_s)
        trusted_proxies.any? { |network| network.include?(address) }
      rescue IPAddr::Error
        false
      end

      # Drops the memoized config (tests / APP_ENV changes).
      def reset!
        @trusted_proxies  = nil
        @trust_cloudflare = nil
      end

      private

      def parse(value)
        return nil if value.to_s.strip.empty?

        value.split(",").map { |cidr| IPAddr.new(cidr.strip) }
      rescue IPAddr::Error
        nil
      end

      def presence(value)
        value.to_s.strip.empty? ? nil : value.to_s.strip
      end
    end
  end
end
