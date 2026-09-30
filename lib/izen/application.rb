# frozen_string_literal: true

require "roda"
require "rack/method_override"

require_relative "base/session_plugin"

module Izen
  # Base Roda application every Izen project subclasses.
  #
  # It wires the plugins a generated app always needs — template rendering,
  # flash messages and the signed-cookie session — and anchors their paths and
  # cookie key to the host application root (Izen.root). The subclass only has to
  # declare its routes:
  #
  #   class App < Izen::Application
  #     route do |r|
  #       r.root { view("home") }
  #     end
  #   end
  #
  # Plugins are configured in .inherited rather than in this class body so the
  # app directory (Izen.root/app, which holds the views) is resolved *after*
  # the host app calls Izen.configure, not when the gem is first required.
  #
  # :all_verbs adds the r.put / r.delete / r.patch matchers (Roda only ships
  # r.get and r.post), and Rack::MethodOverride lets an HTML form — which can
  # only POST — reach them with a hidden `_method` field (or the
  # X-HTTP-Method-Override header).
  class Application < Roda
    class << self
      def inherited(subclass)
        super

        subclass.opts[:root] = Izen.root
        subclass.plugin :all_verbs
        subclass.plugin :render, views: "app"
        subclass.plugin :flash
        subclass.plugin :memory_session, key: "#{session_key(subclass)}_session"
        subclass.use Rack::MethodOverride
      end

      private

      # Cookie name for the session, derived from the subclass name so two apps
      # in the same browser do not share a session: App -> app_session.
      def session_key(subclass)
        name = subclass.name.to_s.split("::").last
        return "izen" if name.empty?

        name.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end
    end
  end
end
