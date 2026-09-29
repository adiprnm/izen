# frozen_string_literal: true

module Izen
  module Cli
    # Renders the Kamal deploy files shared by `izen new` (scaffolding them at
    # the project root) and `izen native build` (copying them into the
    # generated `native/` project, where the Dockerfile and `pack/` live).
    #
    # Keep the templates boring: a fresh project gets a working `deploy.yml`
    # plus an empty `.kamal/secrets-common` that pulls the two Izen secrets from
    # the environment. (Kamal reads `secrets-common` for every deploy, whereas
    # `.kamal/secrets` is ignored once `-d <destination>` is passed.) Everything the user must edit (server, host, registry) is
    # left as an obvious placeholder.
    module Kamal
      module_function

      # The `config/deploy.yml` contents for +name+ (the app/project name).
      def deploy_yml(name)
        slug = slug(name)

        <<~YAML
          # Kamal deployment configuration for #{name}.
          #
          # `izen new` writes this at the project root. `izen native build`
          # copies it into the generated native/ project (patching the proxy
          # port), which is where the Dockerfile and pack/ build context live.
          # Deploy the native binary with:
          #
          #   izen native build
          #   cd native && kamal setup    # first time; then: kamal deploy
          #
          # Docs: https://kamal-deploy.org/docs/configuration/

          # Name of the application. Used to uniquely configure containers.
          service: #{slug}

          # Name of the container image. Change the account if you push to a
          # registry other than the built-in local registry below.
          image: #{slug}

          # Deploy to these servers.
          servers:
            web:
              - 192.168.0.1

          # Enable SSL auto certification via Let's Encrypt.
          proxy:
            ssl: true
            host: example.com
            # The native server listens on :3000 (see the Dockerfile).
            app_port: 3000
            healthcheck:
              path: /
              interval: 5
              timeout: 5

          # Credentials for the image host. `localhost:5555` uses Kamal's
          # built-in local registry on the server, so no account is required.
          registry:
            server: localhost:5555

          # Build for the architecture of the server.
          builder:
            arch: amd64

          # Inject ENV variables into containers (secrets come from .kamal/secrets-common).
          env:
            clear:
              APP_ENV: production
            secret:
              - SESSION_SECRET
              - APP_ENCRYPTION_KEY

          # Persistent volume for the SQLite database and the session secret.
          volumes:
            - "#{slug}_storage:/app/storage"

          # Aliases are triggered with "kamal <alias>".
          aliases:
            shell: app exec --interactive --reuse "sh"
            logs: app logs -f
        YAML
      end

      # The `.kamal/secrets-common` contents: it references the Izen secrets from the
      # environment instead of storing raw credentials.
      def secrets(_name = nil)
        <<~SECRETS
          # Secrets for config/deploy.yml. Safe to keep out of version control.
          # Export the values (or source them from a password manager) before
          # running `kamal deploy`; do not paste raw credentials here.
          SESSION_SECRET=$SESSION_SECRET
          APP_ENCRYPTION_KEY=$APP_ENCRYPTION_KEY
        SECRETS
      end

      # A lowercase, dash-separated identifier acceptable to Kamal for the
      # service/image/volume names.
      def slug(name)
        name.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      end
    end
  end
end
