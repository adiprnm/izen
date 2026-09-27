# frozen_string_literal: true

require_relative "lib/izen/version"

Gem::Specification.new do |spec|
  spec.name    = "izen"
  spec.version = Izen::VERSION
  spec.authors = [ "Adi Purnama" ]
  spec.email   = [ "adiprnm2014@gmail.com" ]

  spec.summary     = "A lightweight, module-first core for Roda + SQLite apps (no ORM)."
  spec.description = <<~DESC
    Izen (from "Rubizen" / Ruby Zen) provides plain-Ruby base classes — Model,
    Contract, Repository, Controller, Session, Job and Mailer — plus a
    thread-local SQLite connection, an HTTP client, an AES-256-GCM encryptor, a
    minimal .env loader, and a CLI for migrations and module scaffolding. No ORM,
    no autoloader, no framework magic.
  DESC
  spec.homepage    = "https://github.com/adipurnm/izen"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.1"

  spec.files         = Dir["lib/**/*", "exe/*", "README.md", "LICENSE.txt"]
  spec.bindir        = "exe"
  spec.executables   = [ "izen" ]
  spec.require_paths = [ "lib" ]

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.add_dependency "mail", "~> 2.8"
  spec.add_dependency "roda", "~> 3.0"
  spec.add_dependency "sqlite3", "~> 2.0"
end
