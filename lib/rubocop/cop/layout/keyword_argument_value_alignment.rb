# frozen_string_literal: true

module RuboCop
  module Cop
    module Layout
      # Aligns the values of keyword arguments in a multi-line method definition
      # (most visibly `initialize`), so the defaults line up in a column:
      #
      #   def initialize(
      #     app,
      #     repository:  Repository.new,
      #     pages:       Pages::Repository.new,
      #     view_events: ViewEvents::Repository.new
      #   )
      #
      # RuboCop's Layout/HashAlignment covers hash literals and keyword arguments
      # passed to method calls, but not keyword *parameters* in a `def`. This cop
      # fills that gap.
      class KeywordArgumentValueAlignment < Base
        extend AutoCorrector

        MSG = "Align the values of keyword arguments."

        def on_def(node)
          check(node)
        end
        alias on_defs on_def

        private

        def check(node)
          kwoptargs = node.arguments.select(&:kwoptarg_type?)
          return if kwoptargs.size < 2

          alignable = kwoptargs.select do |arg|
            value = arg.children[1]
            arg.first_line == value.first_line && value.first_line == value.last_line
          end
          return if alignable.size < 2
          return if alignable.map(&:first_line).uniq.size != alignable.size

          # Compare columns, not absolute offsets: the names sit on different
          # lines, so their absolute positions differ by the line lengths.
          max_column = alignable.map { |arg| arg.loc.name.last_column }.max

          alignable.each do |arg|
            name_end    = arg.loc.name.end_pos
            value_begin = arg.children[1].source_range.begin_pos
            range       = Parser::Source::Range.new(processed_source.buffer, name_end, value_begin)
            expected    = ":" + (" " * (max_column - arg.loc.name.last_column + 1))
            next if range.source == expected

            add_offense(range, message: MSG) do |corrector|
              corrector.replace(range, expected)
            end
          end
        end
      end
    end
  end
end
