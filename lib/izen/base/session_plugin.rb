# frozen_string_literal: true

require "roda"

require_relative "session"

class Roda
  module RodaPlugins
    # Signed-cookie sessions without OpenSSL.
    #
    # Provides the same +session+ method as Roda's :sessions plugin (so the
    # :flash plugin keeps working unchanged), but persists a signed, not
    # encrypted, cookie. See Base::Session for why.
    #
    #   plugin :memory_session, key: "modular_session"
    module MemorySession
      def self.configure(app, opts = {})
        app.opts[:memory_session] = {
          key:     "modular_session",
          max_age: 30 * 24 * 60 * 60
        }.merge(opts).freeze
      end

      module InstanceMethods
        # The current session hash, loaded from the signed cookie. Published
        # as env["rack.session"] for Rack-aware helpers and tests.
        def session
          @_session ||= begin
            data                = ::Izen::Base::Session.decode(request.cookies[self.class.opts[:memory_session][:key]])
            env["rack.session"] = data
            data
          end
        end

        private

        # Numbered after :flash (40) so flash changes are persisted too.
        def _roda_after_50__memory_session(res)
          # Roda's error handler calls this with a nil response when the route
          # raised before producing one; there is nothing to write then.
          return unless res && @_session

          opts = self.class.opts[:memory_session]
          if @_session.empty?
            if request.cookies.key?(opts[:key])
              ::Rack::Utils.delete_cookie_header!(res[1], opts[:key], { path: "/" })
            end
          else
            ::Rack::Utils.set_cookie_header!(
              res[1],
              opts[:key],
              {
                value:     ::Izen::Base::Session.encode(@_session),
                path:      "/",
                httponly:  true,
                same_site: :lax,
                secure:    request.ssl?,
                max_age:   opts[:max_age]
              }
            )
          end
        end
      end
    end

    register_plugin(:memory_session, MemorySession)
  end
end
