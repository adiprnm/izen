# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "open3"
require "rbconfig"
require "socket"
require "timeout"
require "tmpdir"
require "uri"

module Izen
  module Native
    # Differential ("parity") harness for the native lowering.
    #
    # One scenario sequence is replayed against several builds of the *same* app
    # and the observable responses are compared:
    #
    #   * the source Roda app on CRuby          (the reference)
    #   * the generated project on CRuby        (does the generator preserve behaviour?)
    #   * the compiled Spinel binary            (does Spinel/the FFI adapter preserve it?)
    #
    # It is deliberately dependency-free (stdlib + Rack, which Izen already
    # needs) so a scaffolded app can require it from its `native:verify` task
    # without pulling the whole transpiler. `izen/native` is only needed to
    # build, which the caller does.
    #
    #   Izen::Native::Conformance.rack(app_root, scenarios: SCENARIOS)
    #   Izen::Native::Conformance.cruby(generated_root, scenarios: SCENARIOS)
    #   Izen::Native::Conformance.binary(executable, root, scenarios: SCENARIOS)
    #
    # Comparisons are stateful: the cookie a response sets is replayed on the
    # next request, so session/flash behaviour is compared — not the cookie name
    # or its signed value, which legitimately differ between backends. Only the
    # behaviour-level surface (status, Location, body) is compared; transport
    # headers such as Content-Type/Date are the domain of the HTTP tests.
    module Conformance
      # The gem's `lib/` directory, prepended to the driver's load path so
      # `require "izen"` resolves to the same code under test.
      LIB_DIR = File.expand_path("../..", __dir__)

      # Marks the JSON payload in the driver's stdout (which may also carry
      # migration output).
      PAYLOAD_MARKER = "---IZEN-CONFORMANCE---"

      # Safe smoke checks for any app: the root page and a path that must 404.
      DEFAULT_SCENARIOS = [
        { "id" => "root",      "method" => "GET", "path" => "/" },
        { "id" => "not-found", "method" => "GET", "path" => "/izen-conformance-missing" }
      ].freeze

      # Runs the scenarios against the source Roda app on CRuby.
      def self.rack(source_root, scenarios: DEFAULT_SCENARIOS)
        run_driver(RACK_DRIVER, source_root, scenarios)
      end

      # Runs the scenarios against the generated project on CRuby.
      def self.cruby(generated_root, scenarios: DEFAULT_SCENARIOS)
        run_driver(NATIVE_DRIVER, generated_root, scenarios)
      end

      # Boots a compiled native binary, replays the scenarios over HTTP and
      # shuts it down. The database is removed first so the run starts from an
      # empty schema.
      def self.binary(executable, root, scenarios: DEFAULT_SCENARIOS)
        port = free_port
        reset_database(root)

        env = {
          "APP_ENV"            => "test",
          "SESSION_SECRET"     => "conformance-secret-" * 4,
          "APP_ENCRYPTION_KEY" => "conformance-encryption-key",
          "PORT"               => port.to_s
        }
        pid = Process.spawn(env, executable, chdir: root, out: File::NULL, err: File::NULL)
        begin
          wait_for_port(port)
          drive_http(port, scenarios)
        ensure
          stop(pid)
        end
      end

      # Replays the scenarios over HTTP against an already-running server.
      def self.drive_http(port, scenarios = DEFAULT_SCENARIOS)
        cookie  = nil
        results = []

        scenarios.each do |scenario|
          uri                                                          = URI("http://127.0.0.1:#{port}#{scenario["path"]}")
          http                                                         = Net::HTTP.new(uri.host, uri.port)
          request                                                      = Net::HTTP.const_get(scenario["method"].capitalize).new(uri)
          (scenario["headers"] || {}).each { |key, value| request[key] = value }
          request["cookie"]                                            = cookie if cookie
          request.body                                                 = scenario["body"] if scenario["body"]

          response   = http.request(request)
          set_cookie = response["set-cookie"]
          cookie     = set_cookie.split(";").first if set_cookie

          results << normalize(scenario["id"], response.code, response["location"], response.body)
        end

        results
      end

      # Returns a human-readable list of the first field that differs per
      # scenario, or an empty array when the two runs agree.
      def self.differences(expected, actual)
        expected.zip(actual).flat_map do |e, a|
          next [] unless e && a

          %w[status location body].filter_map do |field|
            next if e[field] == a[field]

            "#{e["id"]}: #{field} differs\n  expected: #{e[field].inspect}\n  actual:   #{a[field].inspect}"
          end
        end
      end

      # Parses scenarios from a Ruby file that defines
      # `NativeScenarios::SCENARIOS` (the scaffolded `test/native_scenarios.rb`),
      # falling back to +default+ when the file is absent.
      def self.load_scenarios(path, default: DEFAULT_SCENARIOS)
        return default unless File.file?(path)

        require File.expand_path(path)
        return default unless Object.const_defined?(:NativeScenarios)

        Object.const_get(:NativeScenarios)::SCENARIOS
      end

      def self.normalize(id, status, location, body)
        {
          "id"       => id,
          "status"   => status.to_i,
          "location" => location,
          "body"     => body.to_s
        }
      end
      private_class_method :normalize

      # --- subprocess drivers ------------------------------------------------

      def self.run_driver(source, app_root, scenarios)
        Dir.mktmpdir("izen-conformance") do |dir|
          driver         = File.join(dir, "driver.rb")
          scenarios_path = File.join(dir, "scenarios.json")
          File.write(driver, source)
          File.write(scenarios_path, JSON.generate(scenarios))

          out, err, status = Open3.capture3(
            {
              "APP_ENV"            => "test",
              "SESSION_SECRET"     => "conformance-secret-" * 4,
              "APP_ENCRYPTION_KEY" => "conformance-encryption-key"
            },
            RbConfig.ruby,
            "-I",
            LIB_DIR,
            driver,
            app_root,
            scenarios_path,
            chdir: app_root
          )

          payload = out[/#{PAYLOAD_MARKER}\n(.*)\z/m, 1]
          unless status.success? && payload
            raise "conformance driver failed (#{status.exitstatus}):\n#{out}\n#{err}"
          end

          JSON.parse(payload)
        end
      end
      private_class_method :run_driver

      def self.wait_for_port(port, timeout: 20)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          begin
            return TCPSocket.new("127.0.0.1", port).close
          rescue SystemCallError
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
              raise "native server did not start on port #{port}"
            end

            sleep 0.1
          end
        end
      end
      private_class_method :wait_for_port

      def self.stop(pid)
        Process.kill("TERM", pid)
        Timeout.timeout(10) { Process.wait(pid) }
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      rescue Timeout::Error
        Process.kill("KILL", pid)
        Process.wait(pid)
      end
      private_class_method :stop

      def self.free_port
        server = TCPServer.new("127.0.0.1", 0)
        server.addr[1]
      ensure
        server&.close
      end
      private_class_method :free_port

      def self.reset_database(root)
        Dir[File.join(root, "storage", "test.db*")].each { |path| FileUtils.rm_f(path) }
      end
      private_class_method :reset_database

      # Source Roda app: call it through Rack with the same request data the HTTP
      # server would build.
      RACK_DRIVER = <<~'RUBY'
        require "json"
        require "stringio"
        require "rack"
        require "izen"
        require "izen/cli"

        root      = ARGV[0]
        scenarios = JSON.parse(File.read(ARGV[1]))
        Dir.chdir(root)
        require File.join(root, "app")
        Izen::Cli.migrate

        cookie  = nil
        results = []

        scenarios.each do |scenario|
          headers = (scenario["headers"] || {}).dup
          headers["cookie"] = cookie if cookie

          path = scenario["path"].to_s
          path += "?#{scenario["query"]}" if scenario["query"] && !scenario["query"].to_s.empty?

          env = Rack::MockRequest.env_for(path, method: scenario["method"])
          headers.each do |key, value|
            name = key.to_s.downcase
            case name
            when "content-type" then env["CONTENT_TYPE"] = value
            when "cookie"       then env["HTTP_COOKIE"]  = value
            else                     env["HTTP_#{name.upcase.tr('-', '_')}"] = value
            end
          end
          env["rack.input"] = StringIO.new(scenario["body"].to_s) if scenario["body"]

          status, response_headers, body = App.call(env)
          buffer = +""
          body.each { |chunk| buffer << chunk }
          body.close if body.respond_to?(:close)

          set_cookie = response_headers["set-cookie"] || response_headers["Set-Cookie"]
          cookie = set_cookie.to_s.split(";").first if set_cookie && !set_cookie.to_s.empty?

          results << {
            "id"       => scenario["id"],
            "status"   => status,
            "location" => response_headers["location"] || response_headers["Location"],
            "body"     => buffer
          }
        end

        puts "---IZEN-CONFORMANCE---"
        puts JSON.generate(results)
      RUBY

      # Generated project on CRuby: the same `App#call` the Spinel server drives.
      NATIVE_DRIVER = <<~'RUBY'
        require "json"

        ENV["APP_ENV"] = "test"
        root      = ARGV[0]
        scenarios = JSON.parse(File.read(ARGV[1]))
        Dir.chdir(root)
        require File.join(root, "app")
        Database.migrate!

        cookie  = nil
        results = []

        scenarios.each do |scenario|
          headers = (scenario["headers"] || {}).dup
          headers["cookie"] = cookie if cookie

          request  = Request.new(scenario["method"], scenario["path"], scenario["query"].to_s, scenario["body"].to_s, headers)
          response = App.new.call(request)

          set_cookie = response.headers["Set-Cookie"]
          cookie = set_cookie.to_s.split(";").first if set_cookie && !set_cookie.to_s.empty?

          results << {
            "id"       => scenario["id"],
            "status"   => response.status,
            "location" => response.headers["Location"],
            "body"     => response.body.to_s
          }
        end

        puts "---IZEN-CONFORMANCE---"
        puts JSON.generate(results)
      RUBY
    end
  end
end
