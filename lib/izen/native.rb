# frozen_string_literal: true

require_relative "native/analyzer"
require_relative "native/generator"
require_relative "native/builder"

# Native — lower an Izen (Roda + SQLite) app to a Spinel-compilable `spin`
# project so it can be built into a single native binary.
#
# The transpiler runs on CRuby and needs Prism (AST) and Erubi (byte-identical
# view precompilation). It is required lazily by the CLI, so `require "izen"`
# stays lightweight.
module Izen
  module Native
  end
end
