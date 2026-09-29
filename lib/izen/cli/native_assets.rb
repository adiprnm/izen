# frozen_string_literal: true

module Izen
  module Cli
    # Static files for the native (Spinel) image build.
    #
    # `Dockerfile.native` lives at the project root next to the app's own
    # `Dockerfile` (and `config/deploy.native.yml` next to `config/deploy.yml`).
    # `izen new` scaffolds both; any `izen native` command writes the Dockerfile
    # when it is missing so an existing project keeps working.
    #
    # The Dockerfile is built with the generated `native/` directory as the
    # build context (see `builder.context` in the native deploy config), so the
    # COPY paths below are relative to that directory, not the project root.
    module NativeAssets
      module_function

      def dockerfile
        <<~DOCKER
          # syntax=docker/dockerfile:1
          # Build the Spinel binary from the packed C sources, then ship a minimal
          # runtime image. Build context is the generated native/ directory (see
          # builder.context in config/deploy.native.yml); run `izen native pack`
          # first so native/pack exists.
          FROM debian:bookworm-slim AS build
          RUN apt-get update -qq \\
           && apt-get install --no-install-recommends -y clang make libsqlite3-dev libssl-dev libcrypt-dev \\
           && rm -rf /var/lib/apt/lists/*
          COPY pack /src
          RUN make -C /src clean || true
          RUN make -C /src -j"$(nproc)" CC=clang

          FROM debian:bookworm-slim
          # ca-certificates is required: the native HTTP/SMTP clients verify TLS
          # against the system trust store (R2, Midtrans, SMTP), and the slim base
          # image ships no CA bundle.
          RUN apt-get update -qq \\
           && apt-get install --no-install-recommends -y ca-certificates libsqlite3-0 libssl3 libcrypt1 libvips-tools \\
           && rm -rf /var/lib/apt/lists/*
          WORKDIR /app
          COPY public/ ./public/
          COPY db/ ./db/
          COPY --from=build /src/serve ./serve
          RUN useradd --uid 1001 --create-home app \\
           && mkdir -p storage \\
           && chown -R app:app /app
          USER app
          VOLUME /app/storage
          ENV APP_ENV=production
          ENV PORT=3000
          ENV SPINEL_WORKERS=2
          EXPOSE 3000
          CMD ["./serve"]
        DOCKER
      end

      # Trimmed to the files the native image copies, relative to the `native/`
      # build context.
      def dockerignore
        <<~IGNORE
          build/
          storage/
          test/
          vendor/
          app/
          generated/
          runtime/
          spinel/
          bin/
          *.md
          spin.lock
          pack/**/*.o
        IGNORE
      end
    end
  end
end
