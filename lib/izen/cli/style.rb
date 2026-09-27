# frozen_string_literal: true

module Izen
  module Cli
    # ANSI styling for CLI output.
    #
    # Colors are emitted only when the stream being written to is a TTY, so
    # piping or redirecting `izen` output never leaks escape sequences.
    # `NO_COLOR` (set to any non-empty value) disables color, while
    # `FORCE_COLOR` (set to anything but "0") forces it on even for a non-TTY
    # stream — handy when paging output.
    #
    # Callers compose output from the semantic helpers (`created`, `migrated`,
    # `error`, ...) so every command shares one visual language.
    module Style
      CODES = {
        bold:    1,
        dim:     2,
        red:     31,
        green:   32,
        yellow:  33,
        blue:    34,
        magenta: 35,
        cyan:    36,
        gray:    90
      }.freeze

      UTF8 = [ ENV["LANG"], ENV["LC_ALL"] ].compact.any? { |value| value.match?(/utf-?8/i) }

      CHECK = UTF8 ? "✔" : "*"
      CROSS = UTF8 ? "✖" : "x"
      DOT   = UTF8 ? "•" : "-"
      UNDO  = UTF8 ? "↩" : "<"

      module_function

      # True when the given stream should receive ANSI escapes.
      def enabled?(stream = $stdout)
        return false unless ENV["NO_COLOR"].to_s.empty?
        return true if forced?

        stream.respond_to?(:tty?) && stream.tty?
      end

      def forced?
        value = ENV["FORCE_COLOR"].to_s
        !value.empty? && value != "0"
      end

      # Wraps +text+ in the given style keys, e.g. `paint("hi", :green, :bold)`.
      def paint(text, *styles, stream: $stdout)
        text = text.to_s
        return text unless enabled?(stream)

        codes = styles.filter_map { |style| CODES[style] }
        return text if codes.empty?

        "\e[#{codes.join(';')}m#{text}\e[0m"
      end

      # --- colors -------------------------------------------------------------

      def cyan(text)
        paint(text, :cyan)
      end

      def green(text)
        paint(text, :green)
      end

      def yellow(text)
        paint(text, :yellow)
      end

      def bold(text)
        paint(text, :bold)
      end

      def dim(text)
        paint(text, :dim)
      end

      # --- semantic pieces ----------------------------------------------------

      # Section title in usage/banners.
      def heading(text)
        paint(text, :bold, :cyan)
      end

      # A literal command (`izen migration migrate`) or a syntax line.
      def command(text)
        paint(text, :bold, :cyan)
      end

      # An option flag (`--force`).
      def flag(text)
        paint(text, :yellow)
      end

      # A file/directory path.
      def path(text)
        paint(text, :cyan)
      end

      # Outlined prompt, used for generated "next steps".
      def step(text)
        paint(text, :cyan)
      end

      # An error line written to stderr (abort with this string).
      def error(text)
        paint("#{CROSS} #{text}", :red, :bold, stream: $stderr)
      end

      # A warning line.
      def warning(text)
        paint("#{DOT} #{text}", :yellow)
      end

      # --- output lines -------------------------------------------------------

      def created(detail)
        action("created", detail)
      end

      def updated(detail)
        action("updated", detail)
      end

      def migrated(detail)
        action("migrated", detail)
      end

      def generated(detail)
        action("generated", detail)
      end

      def built(detail)
        action("built", detail)
      end

      def packed(detail)
        action("packed", detail)
      end

      def removed(detail)
        action("removed", detail)
      end

      def rolled_back(detail)
        action("rolled back", detail, color: :yellow, marker: UNDO)
      end

      def skipped(detail)
        action("skipped", detail, color: :yellow, marker: DOT)
      end

      # A no-op line, e.g. "nothing to migrate".
      def nothing(detail)
        "#{paint(DOT, :dim)} #{paint(detail, :dim)}"
      end

      # A `migration status` row: state coloured, filename in cyan.
      def migration_status(state, filename)
        color = state == "up" ? :green : :yellow
        "#{paint(format('%-8s', state), color)} #{paint(filename, :cyan)}"
      end

      def action(verb, detail, color: :green, marker: CHECK)
        [
          paint(marker, color),
          paint(verb, color),
          paint(detail, :cyan)
        ].join(" ")
      end
    end
  end
end
