# frozen_string_literal: true

require_relative "generator"

module Izen
  module Native
    # Raised when the `spin` executable cannot be found on PATH.
    class SpinNotFound < StandardError; end

    # Generates the Spinel project and drives the `spin` toolchain.
    #
    #   builder = Izen::Native::Builder.new(source: ".", out: "./native")
    #   builder.generate(spinel: true)
    #   builder.build
    class Builder
      attr_reader :source, :out

      def initialize(source:, out:, spinel_bin: nil, name: nil)
        @source     = File.expand_path(source)
        @out        = File.expand_path(out)
        @spinel_bin = spinel_bin
        @name       = name
      end

      # Lowers the source app into +out+.
      def generate(spinel: false)
        Generator.new(@source, @out, spinel: spinel, name: @name).run
      end

      # Generates for Spinel and compiles the native binary (`spin build`).
      # `spin` names the binary after the entry script (bin/serve.rb -> serve).
      def build
        resolve_spin # fail fast, before the previous output is removed
        generate(spinel: true)
        spin!("build")
        File.join(@out, "build", "bin", "serve")
      end

      # Generates for Spinel and produces the C-only pack directory
      # (`spin pack --out pack`).
      def pack(pack_out: "pack")
        resolve_spin # fail fast, before the previous output is removed
        generate(spinel: true)
        spin!("pack", "--out", pack_out)
        File.join(@out, pack_out)
      end

      # Generates the CRuby build and boots the development server.
      def run(port: nil)
        generate(spinel: false)
        env = port ? { "PORT" => port.to_s } : {}
        command!("ruby", "bin/serve.rb", chdir: @out, env: env)
      end

      def clean
        FileUtils.rm_rf(@out)
      end

      private

      # Runs `spin` with the optional Spinel bin directory prepended to PATH.
      def spin!(*args)
        spin = resolve_spin
        env  = {}
        if @spinel_bin
          env["PATH"] = "#{File.expand_path(@spinel_bin)}:#{ENV.fetch("PATH", "")}"
        end
        command!(spin, *args, chdir: @out, env: env)
      end

      # Returns the path to the `spin` executable, or raises SpinNotFound with a
      # message that says how to fix it.
      def resolve_spin
        if @spinel_bin
          path = File.join(File.expand_path(@spinel_bin), "spin")
          raise SpinNotFound, "no spin executable at #{path}" unless File.executable?(path)

          path
        else
          found = find_on_path("spin")
          raise SpinNotFound, spin_missing_message unless found

          found
        end
      end

      def find_on_path(name)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
          candidate = File.join(dir, name)
          return candidate if File.file?(candidate) && File.executable?(candidate)
        end
        nil
      end

      def spin_missing_message
        "spin not found on PATH. Install Spinel (https://github.com/matz/spinel) " \
          "and add its bin/ to PATH, or pass --spinel-bin /path/to/spinel/bin " \
          "(or set SPINEL_BIN)."
      end

      def command!(*command, chdir:, env: {})
        puts "$ (cd #{chdir} && #{command.join(' ')})"
        success = system(env, *command, chdir: chdir)
        # `system` returns nil (and prints nothing) when the command could not be
        # executed at all, e.g. because it is not on PATH.
        raise SpinNotFound, spin_missing_message if success.nil? && command.first == "spin"
        raise "#{command.first} failed" unless success

        success
      end
    end
  end
end
