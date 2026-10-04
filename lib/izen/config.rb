# frozen_string_literal: true

require "erb"
require "yaml"

module Izen
  # Loads YAML config files with ERB support, the way Rails' database.yml and
  # storage.yml work, so values can come from the environment at boot:
  #
  #   production:
  #     bucket: "<%= ENV["S3_BUCKET"] %>"
  #     secret_access_key: "<%= ENV["S3_SECRET_ACCESS_KEY"] %>"
  #
  # ERB is evaluated with a plain binding, so only `ENV` (and anything already
  # in scope) is available — config lives in the repository and is trusted.
  module Config
    class Error < StandardError; end

    module_function

    def load_yaml(path)
      template = ERB.new(File.read(path), trim_mode: "-")
      YAML.load(template.result(binding))
    rescue Psych::Exception, SyntaxError, NameError, NoMethodError, ArgumentError => e
      raise Error, "could not parse #{path}: #{e.message}"
    end
  end
end
