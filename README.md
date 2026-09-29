# Izen

**Izen** — a lightweight, module-first core for [Roda](https://roda.jeremyevans.net/)
+ SQLite apps. No ORM, no autoloader, no framework magic.

The name comes from **Rubizen** (Ruby Zen): the core is small, plain Ruby and
deliberately boring. In Basque, *izen* means "name" — a fitting double meaning
for a layer built around models and schemas.

## What's inside

| Piece | Purpose |
|---|---|
| `Izen::Base::Model` | Typed attribute value object (lean `dry-struct`) |
| `Izen::Base::Contract` | Dependency-free params validation (lean `dry-validation`) |
| `Izen::Base::Repository` | Thin wrapper over the SQLite connection, raw SQL |
| `Izen::Base::Controller` | Roda-backed controller base (render, flash, request context) |
| `Izen::Application` | Base Roda app: render, flash, signed-cookie sessions and PUT/PATCH/DELETE (with method override), rooted at `Izen.root` |
| `Izen::Base::Session` | Signed-cookie sessions without OpenSSL |
| `Izen::Base::Job` | Single-thread background job base class + worker |
| `Izen::Base::Batcher` | Write-behind buffer: persist fire-and-forget writes in batches |
| `Izen::Base::Mailer` | Transactional mailer base class |
| `Izen::Database` | Thread-local SQLite connection (WAL + foreign keys) |
| `Izen::HTTP` | Small HTTP client supporting every HTTP method |
| `Izen::Encryptor` | AES-256-GCM for secrets stored in the database |
| `Izen::Dotenv` | Minimal `.env` loader (no dependency) |
| `Izen::Cli` | Project scaffolding, migrations + module scaffolding |
| `Izen::Native` | Lower the app to a [Spinel](https://github.com/matz/spinel) `spin` project and build one native binary |

## Installation

```ruby
# Gemfile
gem "izen"
```

```sh
bundle install
```

## Configuration

Izen resolves every path against a single **host application root**, which
defaults to `Dir.pwd`:

```ruby
# config.ru / boot file, if the app is not started from its own root
Izen.configure do |config|
  config.root = File.expand_path(__dir__)
end
```

The root is where `config/database.yaml`, `migrations/`, `storage/`, `app/`,
`views/` and `.env` live.

## The application class

`Izen::Application` is a Roda subclass that wires up the pieces every app
needs. Subclass it and declare your routes:

```ruby
class App < Izen::Application
  route do |r|
    r.root { view("home") }
  end
end
```

It enables `:render` (views under `Izen.root/views`), `:flash` and the
signed-cookie `:memory_session` plugin, deriving the session cookie name from
the subclass name (`App` → `app_session`).

It also enables `:all_verbs` so routes can match `r.put`, `r.patch` and
`r.delete`, and installs `Rack::MethodOverride` so a form — which can only
`POST` — can reach them:

```erb
<form method="post" action="/widgets/1">
  <input type="hidden" name="_method" value="delete">
  <button>Delete</button>
</form>
```

## Batched writes

`Izen::Base::Batcher` is a write-behind buffer for fire-and-forget data
(analytics, logs, metrics): it collects items in memory and persists them in
one transaction per batch from a background worker, so N slow commits (one
fsync each) become one. Subclass it and implement `#perform(batch)`; the batch
runs in the worker thread, so a connection resolved there is the worker's own:

```ruby
class ViewWriter < Izen::Base::Batcher
  def perform(batch)
    db.transaction { batch.each { |row| db.execute(INSERT, row) } }
  end
end

VIEWS = ViewWriter.new(interval: 2, max_size: 500)
VIEWS.push(row) # returns immediately
```

The buffer lives in memory: items not yet flushed are lost on `SIGKILL` or a
crash, but a graceful shutdown flushes them (the native server calls
`Batcher.flush_all`). Use it for analytics-like data, not transactions.

## The CLI

```sh
izen new blog                          # scaffold a new project in ./blog

izen dev                               # boot the dev server on :3000
izen dev --port 4000 --host 0.0.0.0    # bind a custom address

izen migration generate create_users   # empty up/down migration pair
izen migration migrate                 # run pending up migrations
izen migration rollback [STEP]         # roll back the last STEP migrations
izen migration status                  # show applied/pending migrations

izen module new post title:string body:text    # scaffold a domain module
```

`izen new` writes a runnable Roda + SQLite skeleton: `app.rb`, `config.ru`,
`config/database.yaml`, `views/layout.erb`, `Rakefile`, `README.md`,
`.env.example`, a smoke test, and the `app/`, `migrations/` and `storage/`
directories. It also scaffolds a Kamal deploy setup — `config/deploy.yml`
(CRuby), `config/deploy.native.yml` and `Dockerfile.native` (native) and
`.kamal/secrets-common` — for the native build (see
[Kamal deployment](#kamal-deployment)).
The generated `.gitignore` ignores Bundler caches, local `.env` files (keeping
`.env.example`), the local CRuby `config/deploy.yml` and `.kamal/`, `/log/`,
`/tmp/` and `/coverage/`, the SQLite databases and session secret under
`storage/`, Spinel's `native/` build output, and editor/OS noise. The native
deploy template (`config/deploy.native.yml`) and `Dockerfile.native` are kept
tracked. Pass `--force` to scaffold
into a non-empty directory or `--no-test` to skip the test files.

`izen module new` writes `app/<name>/{model,contract,repository,controller}.rb`,
colocated tests, views, a migration and a route entry in `app.rb`. The module
name is **singular** (`post`, `blog_post`): the namespace, directory and views
use it as-is, while the SQL table and the routes are **plural** (`posts`,
`blog_posts`) — the generator pluralises for you. Passing a plural name aborts
with the singular form to use.

Generated routes are RESTful: `index`/`create` on `/posts`, `show`/`update`/
`destroy` on `/posts/:id`. `update` and `destroy` use the `PUT` and `DELETE`
verbs (via Roda's `:all_verbs`); the generated edit/delete forms reach them by
POSTing a hidden `_method=put` / `_method=delete` field that `Rack::MethodOverride`
converts.

`izen dev` boots the app's `config.ru` through `rackup` (Puma when the app's
Gemfile ships it), running from the app root and preferring `bundle exec` when
the bundle actually includes `rackup` (falling back to the standalone `rackup`
with a warning otherwise). It binds port 3000 by default; `--port`/`-p`,
`--host`/`-o`, `--config`/`-c` and `--env`/`-e` (the latter sets `APP_ENV`) are
supported, with `PORT` and `HOST` from the environment as defaults.

CLI output is colorized on a TTY: green for created/migrated files, yellow for
pending migrations and skips, red for errors, cyan for paths and commands. Piped
output stays plain; set `FORCE_COLOR=1` to keep colors when paging, or
`NO_COLOR=1` to turn them off.

## Native binary (Spinel)

`izen native` lowers the app to a [`spin`](https://github.com/matz/spinel)
project — one native binary, no interpreter, no Roda, no Rack, no Puma — and
builds it. The framework runtime (model/contract/repository/controller,
Rack-lite request/response, session/flash, the HTTP server) is hand-written once
in a Spinel-compatible subset; only the metaprogrammed DSLs are lowered:

| Source DSL | Emitted form |
|---|---|
| `attribute :x, T, required:, default:` | explicit readers + `self.attributes` spec |
| `params { required/optional }` | `self.fields` spec |
| `rule { ... }` | `rules` method |
| `route do \|r\| ... end` | explicit `if`/`return` dispatcher |
| `views/**/*.erb` | precompiled Ruby (Erubi codegen, byte-identical to Tilt) |
| `Repository#model_class` | static `to_model`/`to_models` per repository |

```sh
izen native generate        # write the spin project to ./native (CRuby target)
izen native build           # generate --spinel, then `spin build`
izen native pack            # generate --spinel, then `spin pack` (build from C alone)
izen native run             # generate (CRuby) and boot ./native/bin/serve.rb
izen native clean           # remove ./native
```

Options: `--source PATH`, `--out PATH`, `--name NAME`, `--spinel-bin PATH`
(or `SPINEL_BIN`), `--spinel`, `--port PORT`, `--pack-out PATH`.

Requirements: the transpiler runs on CRuby and needs `prism` and `erubi` (both
shipped as Izen dependencies). `izen native build` additionally needs Spinel on
the `PATH` (or `--spinel-bin`); `izen native generate`/`run` do not.

Spinel is built from source (there is no `gem install spinel`):

```sh
git clone --depth 1 https://github.com/matz/spinel ~/tools/spinel
cd ~/tools/spinel && make deps && make
make install PREFIX=$HOME/.local   # -> ~/.local/bin/{spin,spinel}

# `make install` ships the runtime archives (.a) but not the runtime C sources
# that `spin pack` needs, so add them:
cp lib/*.c $HOME/.local/lib/spinel/lib/
cp -r lib/regexp $HOME/.local/lib/spinel/lib/regexp
```

`make install` copies the runtime libraries, `packages/` and `builtins/` next
to the binaries, so `izen native build` is self-contained and the checkout can
be removed afterwards. `izen native pack` additionally needs the runtime C
sources above (it produces a pack that builds from C alone). `~/.local/bin`
must be on `PATH`.

The generated project is plain Ruby in Spinel's subset, so it also runs on
CRuby for development and testing:

```sh
izen native generate
cd native && bundle install
APP_ENV=test ruby -e 'require "./app"; Database.migrate!'
```

Scaffolded projects get `rake native:generate`, `rake native:build`,
`rake native:run` and `rake native:verify` tasks, and `native/` is git-ignored.

### Behavioural parity

Because the generated project is plain Ruby, it also runs on CRuby — which is
what makes parity testable. `Izen::Native::Conformance` replays one stateful
request sequence against the source Roda app, the generated project on CRuby and
the compiled native binary, and compares status, redirect target and body.
Cookie names/values and transport headers (`Content-Type`, `Date`) are
deliberately **not** compared: they legitimately differ between the runtimes,
while the behaviour they carry — the redirect, the rendered body — must not.

**Framework parity** (the lowering itself) is gated by the gem's own suite:

```sh
bundle exec rake test                # source vs generated-on-CRuby
bundle exec rake native:conformance  # also compiles the binary and compares it
```

`rake test` needs no Spinel. `rake native:conformance` runs `spin build` and
adds the compiled binary as a third backend, so a regression that only shows up
under Spinel or the FFI SQLite adapter fails before it reaches production.

**App parity** (your routes and views) is scaffolded into every new project:
`izen new` writes `test/native_scenarios.rb`, and `rake native:verify` diffs the
app on CRuby against the compiled binary over those scenarios:

```sh
bundle exec rake native:verify
```

Edit `test/native_scenarios.rb` to add the read paths (and, if you want, write
flows) you care about. Both runs start from a fresh test database, so keep
scenarios deterministic. `rake native:verify` builds to `tmp/native-verify/`.
A baseline assertion on the reference keeps the gem's own scenario honest (a
wall of empty 200s cannot pass parity).

### Notes and limitations

The generated runtime is written to Spinel's subset. A few non-obvious rules
(learned from the original `spinelhouse` port):

- `+` on a string literal yields an Integer; use `"".dup` for a mutable
  accumulator.
- `.new` on a class read out of a method is refused, which is why repositories
  get generated `to_model`/`to_models` that name the model class literally.
- Spinel does **not** dispatch undefined-method calls to `method_missing`, so
  app helpers declared on the `App` class are also emitted as explicit
  delegators on `Base::Controller`.
- `require "date"` is unsatisfiable, so `Date`/`DateTime` attributes are kept
  as the strings SQLite stores.
- `require "logger"` is unsatisfiable, so the runtime ships a small `Logger`
  stand-in (the common `LOGGER = Logger.new($stdout)` pattern keeps working).
- `bcrypt` is replaced by a shim over libxcrypt's `String#crypt`, so
  `BCrypt::Password` keeps working without the C-extension gem.
- `ruby-vips` is stubbed: image conversion raises and the caller keeps the
  original bytes.
- YAML is unavailable, so the database paths from `config/database.yaml` are
  baked into `generated/database_config.rb` at generation time.

## Kamal deployment

`izen new` scaffolds three deploy files so the app ships with no extra setup:

- `config/deploy.yml` — the CRuby (Roda/Puma) Kamal config, git-ignored like
  any local deploy config.
- `config/deploy.native.yml` — a standalone Kamal config for the native binary,
  tracked in the repository. Its `builder` block pins `context: "native"`
  (the generated build directory that holds `pack/`) and
  `dockerfile: "Dockerfile.native"`.
- `Dockerfile.native` — the native image, tracked at the project root next to
  the app's own `Dockerfile`. It builds the Spinel binary from `native/pack`
  and ships a minimal runtime image.

`.kamal/secrets-common` (git-ignored) reads `SESSION_SECRET` /
`APP_ENCRYPTION_KEY` from the environment for both configs.

Fill in the placeholder server, host and image, then build and deploy the
native binary **from the project root** (Kamal resolves `Dockerfile.native`
relative to the working directory and `native/` as the build context):

```sh
izen native build
export SESSION_SECRET=$(openssl rand -hex 32)
export APP_ENCRYPTION_KEY=$(openssl rand -hex 32)
izen native kamal setup       # first time: provision server/registry/volume
izen native deploy            # build + rolling deploy
```

`izen native deploy` runs `kamal -c config/deploy.native.yml deploy`; its
arguments are deploy options (`-d staging`, `--skip-push`, ...). Use
`izen native kamal <args>` for any other Kamal command (e.g.
`izen native kamal setup`, `izen native kamal app logs`).

`izen native build` lowers the app to a Spinel project in `native/` and writes
`Dockerfile.native` / `config/deploy.native.yml` if they are missing (existing
projects upgrade transparently; your edits are never overwritten). The SQLite
database and the persisted session secret live on the `<name>_native_storage`
volume mounted at `/app/storage`, so redeploys keep their data. The native
service is named `<name>-native` so it can coexist with the CRuby service.

To run a second native environment (say staging) with its own host, image and
volume, add `config/deploy.native.staging.yml` and deploy with
`izen native deploy -d staging`.

The CRuby `config/deploy.yml` and `.kamal/` are git-ignored (they hold server
details and secrets); `config/deploy.native.yml` and `Dockerfile.native` are
tracked templates. Keep the real secrets on disk.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
