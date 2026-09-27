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

  def test_module_new_scaffolds_a_module
    dir       = Dir.mktmpdir("izen-scaffold")
    previous  = Izen.root
    Izen.root = dir
    FileUtils.mkdir_p(File.join(dir, "migrations"))
    File.write(File.join(dir, "app.rb"), "# cli:module-routes\n")

    quiet { Izen::Cli.scaffold("posts", [ [ "title", "string" ] ]) }

    assert File.file?(File.join(dir, "app", "posts", "model.rb"))
    assert File.file?(File.join(dir, "app", "posts", "repository.rb"))
    assert File.file?(File.join(dir, "views", "posts", "index.erb"))
    assert File.file?(File.join(dir, "migrations", "000001_create_posts.up.sql"))
    assert_match(%r{r\.on "posts"}, File.read(File.join(dir, "app.rb")))
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
