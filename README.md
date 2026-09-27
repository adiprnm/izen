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

`izen new` writes a runnable Roda + SQLite skeleton (`app.rb`, `config.ru`,
`config/database.yaml`, `views/layout.erb`, `Rakefile`, a smoke test and the
`app/`, `migrations/` and `storage/` directories). Pass `--force` to scaffold
into a non-empty directory or `--no-test` to skip the test files.

`izen module new` writes `app/<name>/{model,contract,repository,controller}.rb`,
colocated tests, views, a migration and a route entry in `app.rb`.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
