# frozen_string_literal: true

module Izen
  # Conservative allow-list sanitizer for rich-text HTML.
  #
  # Rich text authored in a browser editor is stored as HTML and rendered raw,
  # so a compromised account — or a pasted payload — must not be able to inject
  # scripts. Rather than pull in Nokogiri, this keeps a small set of formatting
  # tags and attributes and strips everything else (keeping the text content).
  #
  #   Izen::Sanitizer.sanitize("<p onclick='x()'>hi</p>") # => "<p>hi</p>"
  #   Izen::Sanitizer.sanitize("<script>alert(1)</script>") # => ""
  #
  # Both the tag/attribute allow-lists and the dropped-block list are constants;
  # reopen the module to change them for your app.
  module Sanitizer
    ALLOWED_TAGS = %w[
      p br strong b em i u s del ins mark blockquote
      ul ol li h1 h2 h3 h4 h5 h6 a code pre span hr
    ].freeze

    ALLOWED_ATTRS = %w[href title].freeze

    VOID_TAGS = %w[br hr].freeze

    # Tags whose entire content is dropped (not just the tag).
    DROPPED_BLOCKS = %w[script style iframe object embed form textarea button svg].freeze

    # URL schemes allowed in an href. A scheme not in this list (javascript:,
    # data:, vbscript:, ...) is dropped.
    SAFE_SCHEMES = %w[http:// https:// mailto:].freeze

    # Matches one HTML attribute: `name="value"`, `name='value'` or `name=value`.
    ATTRIBUTE_PATTERN = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/.freeze

    class << self
      def sanitize(html)
        text = html.to_s
        return "" if text.empty?

        text = text.gsub(/<!--.*?-->/m, "")
        text = drop_blocks(text)
        rewrite_tags(text)
      end

      private

      def drop_blocks(text)
        DROPPED_BLOCKS.each do |tag|
          text = text.gsub(%r{<#{tag}\b.*?</#{tag}\s*>}mi, "")
          text = text.gsub(%r{<#{tag}\b[^>]*/?>}mi, "")
        end
        text
      end

      def rewrite_tags(text)
        text.gsub(%r{</?\s*([a-zA-Z][a-zA-Z0-9]*)((?:[^>"']|"[^"]*"|'[^']*')*)>}) do
          tag     = Regexp.last_match(1).downcase
          attrs   = Regexp.last_match(2).to_s
          closing = Regexp.last_match(0).start_with?("</")

          next "" unless ALLOWED_TAGS.include?(tag)

          if closing
            VOID_TAGS.include?(tag) ? "" : "</#{tag}>"
          elsif VOID_TAGS.include?(tag)
            "<#{tag}>"
          else
            "<#{tag}#{clean_attributes(attrs)}>"
          end
        end
      end

      def clean_attributes(attrs)
        attrs.scan(ATTRIBUTE_PATTERN).filter_map do |name, double, single, bare|
          name = name.downcase
          next unless ALLOWED_ATTRS.include?(name)

          value = (double || single || bare).to_s.strip
          next if name == "href" && unsafe_url?(value)

          %( #{name}="#{escape(value)}")
        end.join
      end

      # Rejects javascript:/data:/vbscript: URLs (including ones obfuscated with
      # whitespace or control characters) while allowing http(s), mailto and
      # relative links.
      def unsafe_url?(value)
        normalized = value.gsub(/[\u0000-\u0020]+/, "").downcase
        return false if normalized.start_with?("/", "#")
        return false if SAFE_SCHEMES.any? { |scheme| normalized.start_with?(scheme) }

        # Any other scheme (javascript:, data:, vbscript:, ...) is unsafe.
        normalized.match?(%r{\A[a-z][a-z0-9+.-]*:})
      end

      def escape(value)
        value.gsub("&", "&amp;").gsub('"', "&quot;").gsub("<", "&lt;").gsub(">", "&gt;")
      end
    end
  end
end
