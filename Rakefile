# frozen_string_literal: true

require "rake/testtask"
require "rbconfig"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning    = false
end

namespace :native do
  desc "Differential parity tests, including a full Spinel build (needs spin on PATH/SPINEL_BIN)"
  task :conformance do
    ENV["IZEN_CONFORMANCE_BUILD"] = "1"
    sh RbConfig.ruby, "-Ilib", "-Itest", "test/izen/conformance_test.rb"
  end
end

task default: :test
