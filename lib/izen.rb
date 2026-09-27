# frozen_string_literal: true

# Izen — a lightweight, module-first core for Roda + SQLite apps (no ORM).
#
# The name comes from "Rubizen" (Ruby Zen): the core is small, plain Ruby and
# deliberately boring. See README.md for the full story.
module Izen
  class << self
    # Host application root: where config/database.yaml, migrations/, app/ and
    # views/ live. Defaults to the current working directory so the gem works
    # without configuration when the app runs from its own root.
    attr_writer :root

    def root
      @root ||= Dir.pwd
    end

    def configure
      yield self
    end
  end
end

require "izen/version"

require "izen/dotenv"
require "izen/encryptor"
require "izen/http"
require "izen/database"

require "izen/base/types"
require "izen/base/format"
require "izen/base/model"
require "izen/base/contract"
require "izen/base/repository"
require "izen/base/controller"
require "izen/base/session"
require "izen/base/session_plugin"
require "izen/base/job"
require "izen/base/mailer"

require "izen/cli"
