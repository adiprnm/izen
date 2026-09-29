# frozen_string_literal: true

require "stringio"

module TestSupport
  # Builds throwaway Izen apps with the real CLI, exactly the way an end user
  # would (`izen new` + `izen module new`). Shared by the native tests: the
  # lowering and the conformance harness both need a representative app.
  module Scaffold
    # Creates `<dir>/demo`, with a `widget` module unless disabled, and returns
    # the project root.
    def scaffold_project(dir, with_module: true)
      previous  = Izen.root
      Izen.root = dir

      quiet { Izen::Cli.run([ "new", "demo" ]) }
      project = File.join(dir, "demo")

      if with_module
        Izen.root = project
        quiet { Izen::Cli.run([ "module", "new", "widget", "name:string", "price:integer", "description:text" ]) }
      end

      project
    ensure
      Izen.root = previous
    end

    # Runs the block with $stdout discarded (the CLI prints progress).
    def quiet
      original = $stdout
      $stdout  = StringIO.new
      yield
    ensure
      $stdout = original
    end
  end
end
