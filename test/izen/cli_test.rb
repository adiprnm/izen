# frozen_string_literal: true

require_relative "../test_helper"

class CliTest < TestSupport::DatabaseTest
  def setup
    super
    @migrations = File.join(Izen.root, "migrations")
    FileUtils.mkdir_p(@migrations)
  end

  def teardown
    FileUtils.rm_rf(@migrations) if @migrations
    super
  end

  def test_migrate_applies_pending_migrations
    write_migration(1, "create_things", "CREATE TABLE things (id INTEGER PRIMARY KEY);", "DROP TABLE things;")

    Izen::Cli.migrate

    assert_equal 1, @db.get_first_value("SELECT COUNT(*) FROM schema_migrations")
    assert_equal 1, @db.get_first_value("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'things'")
  end

  def test_migrate_is_idempotent
    write_migration(1, "create_things", "CREATE TABLE things (id INTEGER PRIMARY KEY);", "DROP TABLE things;")

    Izen::Cli.migrate
    Izen::Cli.migrate

    assert_equal 1, @db.get_first_value("SELECT COUNT(*) FROM schema_migrations")
  end

  def test_rollback_removes_the_last_migration
    write_migration(1, "create_things", "CREATE TABLE things (id INTEGER PRIMARY KEY);", "DROP TABLE things;")

    Izen::Cli.migrate
    Izen::Cli.rollback

    assert_equal 0, @db.get_first_value("SELECT COUNT(*) FROM schema_migrations")
    assert_equal 0, @db.get_first_value("SELECT COUNT(*) FROM sqlite_master WHERE name = 'things'")
  end

  def test_generate_writes_an_up_down_pair
    quiet { Izen::Cli.generate("create_users") }

    assert File.file?(File.join(@migrations, "000001_create_users.up.sql"))
    assert File.file?(File.join(@migrations, "000001_create_users.down.sql"))
  end

  def test_new_scaffolds_a_project
    dir       = Dir.mktmpdir("izen-new")
    previous  = Izen.root
    Izen.root = dir

    quiet { Izen::Cli.run([ "new", "blog" ]) }

    project = File.join(dir, "blog")
    assert File.file?(File.join(project, "Gemfile"))
    assert File.file?(File.join(project, "app.rb"))
    assert File.file?(File.join(project, "config.ru"))
    assert File.file?(File.join(project, "Rakefile"))
    assert File.file?(File.join(project, "config", "database.yaml"))
    assert File.file?(File.join(project, "config", "deploy.yml"))
    assert File.file?(File.join(project, ".kamal", "secrets"))
    assert File.file?(File.join(project, "views", "layout.erb"))
    assert File.file?(File.join(project, "test", "test_helper.rb"))
    assert File.file?(File.join(project, ".gitignore"))
    assert File.directory?(File.join(project, "app"))
    assert File.directory?(File.join(project, "migrations"))
    assert File.directory?(File.join(project, "storage"))

    gitignore = File.read(File.join(project, ".gitignore"))
    assert_includes gitignore, "/storage/*.db"
    assert_includes gitignore, "/storage/session_secret"
    assert_includes gitignore, ".env"
    assert_includes gitignore, "!.env.example"
    assert_includes gitignore, "/native/"
    assert_includes gitignore, "/config/deploy.yml"
    assert_includes gitignore, "/.kamal/"

    deploy = File.read(File.join(project, "config", "deploy.yml"))
    assert_includes deploy, "service: blog"
    assert_includes deploy, "app_port: 3000"
    assert_includes deploy, "blog_storage:/app/storage"

    secrets = File.read(File.join(project, ".kamal", "secrets"))
    assert_includes secrets, "SESSION_SECRET=$SESSION_SECRET"
    assert_includes secrets, "APP_ENCRYPTION_KEY=$APP_ENCRYPTION_KEY"

    readme = File.read(File.join(project, "README.md"))
    assert_includes readme, "## Deploy (Kamal)"
    assert_includes readme, "blog_storage"

    app = File.read(File.join(project, "app.rb"))
    assert_includes app, "class App < Izen::Application"
    assert_includes app, "# cli:module-routes"
    assert_includes app, "Izen.configure"
  ensure
    Izen.root = previous
    FileUtils.remove_entry(dir)
  end

  def test_new_skips_test_files_with_no_test
    dir       = Dir.mktmpdir("izen-new")
    previous  = Izen.root
    Izen.root = dir

    quiet { Izen::Cli.project_new([ "blog", "--no-test" ]) }

    refute File.exist?(File.join(dir, "blog", "test"))
  ensure
    Izen.root = previous
    FileUtils.remove_entry(dir)
  end

  def test_new_refuses_a_non_empty_directory
    dir       = Dir.mktmpdir("izen-new")
    previous  = Izen.root
    Izen.root = dir
    FileUtils.mkdir_p(File.join(dir, "blog"))
    File.write(File.join(dir, "blog", "app.rb"), "# existing\n")

    quiet_errors do
      assert_raises(SystemExit) { Izen::Cli.project_new([ "blog" ]) }
    end

    assert_equal "# existing\n", File.read(File.join(dir, "blog", "app.rb"))
  ensure
    Izen.root = previous
    FileUtils.remove_entry(dir)
  end

  def test_new_force_scaffolds_into_a_non_empty_directory
    dir       = Dir.mktmpdir("izen-new")
    previous  = Izen.root
    Izen.root = dir
    FileUtils.mkdir_p(File.join(dir, "blog"))
    File.write(File.join(dir, "blog", "app.rb"), "# existing\n")

    quiet { Izen::Cli.project_new([ "blog", "--force" ]) }

    assert_includes File.read(File.join(dir, "blog", "app.rb")), "class App < Izen::Application"
  ensure
    Izen.root = previous
    FileUtils.remove_entry(dir)
  end

  def test_dev_command_prefers_bundle_exec_when_the_app_has_a_gemfile
    dir       = Dir.mktmpdir("izen-dev")
    previous  = Izen.root
    Izen.root = dir
    File.write(File.join(dir, "Gemfile"), "source 'https://rubygems.org'\n")

    command = Izen::Cli.dev_command("config.ru", port: "3000", host: "0.0.0.0")

    assert_equal %w[bundle exec rackup config.ru -p 3000 -o 0.0.0.0], command
  ensure
    Izen.root = previous
    FileUtils.remove_entry(dir)
  end

  def test_dev_command_falls_back_to_rackup_without_a_gemfile
    dir       = Dir.mktmpdir("izen-dev")
    previous  = Izen.root
    Izen.root = dir

    assert_equal %w[rackup config.ru -p 3000], Izen::Cli.dev_command("config.ru", {})
  ensure
    Izen.root = previous
    FileUtils.remove_entry(dir)
  end

  def test_dev_options_default_to_port_3000
    options = Izen::Cli.dev_options([])

    assert_equal "3000", options[:port]
  end

  def test_dev_options_parse_port_host_config_and_env
    options = Izen::Cli.dev_options(%w[--port 3000 -o 0.0.0.0 -c web.ru -e production])

    assert_equal "3000",       options[:port]
    assert_equal "0.0.0.0",    options[:host]
    assert_equal "web.ru",     options[:config]
    assert_equal "production", options[:env]
  end

  def test_dev_aborts_when_the_config_file_is_missing
    dir       = Dir.mktmpdir("izen-dev")
    previous  = Izen.root
    Izen.root = dir

    error = assert_raises(SystemExit) { quiet_errors { Izen::Cli.dev([]) } }
    refute_equal 0, error.status
  ensure
    Izen.root = previous
    FileUtils.remove_entry(dir)
  end

  def test_module_new_scaffolds_a_singular_module_with_plural_routes_and_table
    dir       = Dir.mktmpdir("izen-scaffold")
    previous  = Izen.root
    Izen.root = dir
    FileUtils.mkdir_p(File.join(dir, "migrations"))
    File.write(File.join(dir, "app.rb"), "# cli:module-routes\n")

    quiet { Izen::Cli.scaffold("post", [ [ "title", "string" ] ]) }

    assert File.file?(File.join(dir, "app", "post", "model.rb"))
    assert File.file?(File.join(dir, "app", "post", "repository.rb"))
    assert File.file?(File.join(dir, "views", "post", "index.erb"))
    assert File.file?(File.join(dir, "migrations", "000001_create_posts.up.sql"))
    assert_match(%r{CREATE TABLE posts}, File.read(File.join(dir, "migrations", "000001_create_posts.up.sql")))
    assert_match(%r{SELECT \* FROM posts}, File.read(File.join(dir, "app", "post", "repository.rb")))
    assert_match(%r{r\.on "posts"}, File.read(File.join(dir, "app.rb")))
  ensure
    Izen.root = previous
    FileUtils.remove_entry(dir)
  end

  def test_module_new_rejects_a_plural_name
    dir       = Dir.mktmpdir("izen-scaffold")
    previous  = Izen.root
    Izen.root = dir
    FileUtils.mkdir_p(File.join(dir, "migrations"))
    File.write(File.join(dir, "app.rb"), "# cli:module-routes\n")

    error = assert_raises(SystemExit) { quiet_errors { Izen::Cli.scaffold("posts", []) } }
    refute_equal 0, error.status
    refute File.exist?(File.join(dir, "app", "posts"))
  ensure
    Izen.root = previous
    FileUtils.remove_entry(dir)
  end

  private

  def write_migration(version, name, up, down)
    prefix = format("%06d", version)
    File.write(File.join(@migrations, "#{prefix}_#{name}.up.sql"), up)
    File.write(File.join(@migrations, "#{prefix}_#{name}.down.sql"), down)
  end

  def quiet
    original = $stdout
    $stdout  = StringIO.new
    yield
  ensure
    $stdout = original
  end

  def quiet_errors
    original = $stderr
    $stderr  = StringIO.new
    yield
  ensure
    $stderr = original
  end
end
