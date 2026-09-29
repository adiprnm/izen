# frozen_string_literal: true

module Izen
  module Cli
    # Renders the Kamal deploy files shared by `izen new`. A fresh project gets
    # a working CRuby `config/deploy.yml`, a native `config/deploy.native.yml`,
    # and an empty `.kamal/secrets-common` that pulls the two Izen secrets from
    # the environment. (Kamal reads `secrets-common` for every deploy, whereas
    # `.kamal/secrets` is ignored once `-d <destination>` is passed.) Everything
    # the user must edit (server, host, registry) is left as an obvious
    # placeholder.
    module Kamal
      module_function

      # The `config/deploy.yml` contents for +name+ (the app/project name).
      # This is the CRuby (Roda/Puma) deploy config.
      def deploy_yml(name)
        slug = slug(name)

        <<~YAML
          # Kamal deployment configuration for #{name} (CRuby/Puma).
          #
          # `izen new` writes this at the project root as a starting point: fill
          # in the server, host and registry, and ship it with your own
          # Dockerfile. For the native (Spinel) build, use config/deploy.native.yml
          # and Dockerfile.native instead.
          #
          #   kamal -c config/deploy.yml setup    # first time; then: deploy
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

      # The `config/deploy.native.yml` contents for +name+: a standalone Kamal
      # config for the native binary. It sits next to the CRuby `deploy.yml` and
      # is selected explicitly with `kamal -c config/deploy.native.yml ...` (a
      # standalone file, so it is not merged with the CRuby config). +context+ is
      # the generated build directory (holding `pack/`), and +dockerfile+ is the
      # project-root Dockerfile that builds it.
      def deploy_native_yml(name, context: "native", dockerfile: "Dockerfile.native")
        slug = slug(name)

        <<~YAML
          # Kamal deployment configuration for the native (Spinel) build of #{name}.
          #
          # `izen new` writes this next to the CRuby config (config/deploy.yml).
          # The native server listens on :3000, the image is built from the
          # project-root Dockerfile, and the build context is the generated
          # #{context}/ directory that holds pack/ (run `izen native pack`
          # first). Deploy from the project root with:
          #
          #   izen native pack
          #   izen native kamal setup    # first time
          #   izen native deploy         # afterwards
          #
          # Docs: https://kamal-deploy.org/docs/configuration/

          # Name of the application. Used to uniquely configure containers.
          # Kept distinct from the CRuby service so the two can coexist.
          service: #{slug}-native

          # Name of the container image.
          image: #{slug}-native

          # Deploy to these servers.
          servers:
            web:
              - 192.168.0.1

          # Enable SSL auto certification via Let's Encrypt.
          proxy:
            ssl: true
            host: example.com
            # The native server listens on :3000 (see Dockerfile.native).
            app_port: 3000
            healthcheck:
              path: /
              interval: 5
              timeout: 5

          # Credentials for the image host. `localhost:5555` uses Kamal's
          # built-in local registry on the server, so no account is required.
          registry:
            server: localhost:5555

          # Build for the architecture of the server. The Dockerfile lives at
          # the project root; the context is the generated #{context}/ directory.
          builder:
            arch: amd64
            context: "#{context}"
            dockerfile: "#{dockerfile}"

          # Inject ENV variables into containers (secrets come from .kamal/secrets-common).
          env:
            clear:
              APP_ENV: production
            secret:
              - SESSION_SECRET
              - APP_ENCRYPTION_KEY

          # Persistent volume for the SQLite database and the session secret.
          volumes:
            - "#{slug}_native_storage:/app/storage"

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
