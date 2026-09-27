# frozen_string_literal: true

require "erb"
require "fileutils"

module Izen
  module Cli
    # Scaffolds a brand new Izen project: a Roda app, a database config, the
    # app/migrations/views/storage directories and the usual project files.
    #
    #   Cli::ProjectGenerator.new("blog").call
    #
    # File templates live in lib/izen/cli/templates/project/*.tt and are rendered
    # with ERB in the context of this generator (so they can use @name, @title
    # and the helper methods below).
    class ProjectGenerator
      TEMPLATES_DIR = File.expand_path("templates/project", __dir__)

      # Every generated file, relative to the project root.
      FILES = {
        "Gemfile"              => "Gemfile.tt",
        "app.rb"               => "app.rb.tt",
        "config.ru"            => "config.ru.tt",
        "Rakefile"             => "Rakefile.tt",
        "README.md"            => "README.md.tt",
        ".env.example"         => "env.example.tt",
        ".gitignore"           => "gitignore.tt",
        "config/database.yaml" => "database.yaml.tt",
        "views/layout.erb"     => "layout.erb.tt",
        "test/test_helper.rb"  => "test_helper.rb.tt",
        "test/app_test.rb"     => "app_test.rb.tt"
      }.freeze

      # Directories that hold user code/artifacts and must exist up front.
      DIRECTORIES = %w[app migrations storage].freeze

      def initialize(name, force: false, tests: true)
        @target = target_path(name)
        @name   = File.basename(@target)
        @title  = @name.split(/[-_]/).map(&:capitalize).join(" ")
        @force  = force
        @tests  = tests
      end

      def call
        ensure_target!

        DIRECTORIES.each do |dir|
          path = File.join(@target, dir)
          FileUtils.mkdir_p(path)
          FileUtils.touch(File.join(path, ".gitkeep"))
        end

        FILES.each do |path, template|
          next if !@tests && path.start_with?("test/")

          write(path, render(template))
        end

        summary
      end

      private

      # Resolves NAME against the CLI root. "." and absolute paths are kept.
      def target_path(name)
        abort "project name is required" if name.nil? || name.empty?

        File.expand_path(name, Cli.root)
      end

      def write(relative_path, content)
        path = File.join(@target, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        puts "created #{File.join(@name, relative_path)}"
      end

      def ensure_target!
        return unless Dir.exist?(@target)
        return if @force || Dir.empty?(@target)

        abort "#{@name} already exists and is not empty (use --force to scaffold into it)"
      end

      # Renders a .tt template in this generator's binding.
      def render(template)
        source = File.read(File.join(TEMPLATES_DIR, template))
        ERB.new(source, trim_mode: "-").result(binding)
      end

      def summary
        puts
        puts "Project #{@title} created in #{@name}."
        puts
        puts "Next steps:"
        puts "  cd #{@name}"
        puts "  bundle install"
        puts "  bundle exec izen migration migrate"
        puts "  bundle exec rackup"
      end
    end
  end
end
