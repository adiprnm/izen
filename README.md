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

## The CLI

```sh
izen new blog                          # scaffold a new project in ./blog

izen migration generate create_users   # empty up/down migration pair
izen migration migrate                 # run pending up migrations
izen migration rollback [STEP]         # roll back the last STEP migrations
izen migration status                  # show applied/pending migrations

izen module new posts title:string body:text   # scaffold a domain module
```

`izen new` writes a runnable Roda + SQLite skeleton: `app.rb`, `config.ru`,
`config/database.yaml`, `views/layout.erb`, `Rakefile`, `README.md`,
`.env.example`, a smoke test, and the `app/`, `migrations/` and `storage/`
directories. The generated `.gitignore` ignores Bundler caches, local `.env`
files (keeping `.env.example`), `/log/`, `/tmp/` and `/coverage/`, the SQLite
databases and session secret under `storage/`, Spinel's `native/` build output,
and editor/OS noise. Pass `--force` to scaffold into a non-empty directory or
`--no-test` to skip the test files.

`izen module new` writes `app/<name>/{model,contract,repository,controller}.rb`,
colocated tests, views, a migration and a route entry in `app.rb`.

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

Scaffolded projects get `rake native:generate`, `rake native:build` and
`rake native:run` tasks, and `native/` is git-ignored.

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
- YAML is unavailable, so the database paths from `config/database.yaml` are
  baked into `generated/database_config.rb` at generation time.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
