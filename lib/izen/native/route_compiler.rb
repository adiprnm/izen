# frozen_string_literal: true

module Izen
  module Native
    # Compiles an Izen/Roda route block into an explicit `if`/`return`
    # dispatcher.
    #
    # Roda's `r.on` blocks are separate scopes, so the same local name
    # (`controller`) can hold a different class in each. The flattened
    # dispatcher is one method, and Spinel widens a local that is assigned
    # several classes in one scope. To keep each branch's type precise, local
    # variables are renamed with a unique suffix per scope and the rewrite is
    # threaded into nested bodies.
    class RouteCompiler
      LEAF = %i[get post put patch delete options head].freeze

      def initialize(block, source)
        @block   = block
        @source  = source
        @counter = 0
      end

      def compile
        statements = @block&.body&.body || []
        code       = emit_statements(statements, 0, {})
        "#{code}\nresponse.status = 404\n\"\""
      end

      private

      def slice(node)
        Node.slice(@source, node)
      end

      def rewrite(text, env)
        env.each { |original, fresh| text = text.gsub(/\b#{original}\b/, fresh) }
        text
      end

      def emit_statements(statements, offset, env)
        out = +""
        statements.each do |statement|
          code, env = emit_statement(statement, offset, env)
          out << code
        end
        out
      end

      def emit_statement(node, offset, env)
        if node.is_a?(Prism::LocalVariableWriteNode)
          @counter += 1
          fresh     = "#{node.name}_#{@counter}"
          newenv    = env.merge(node.name.to_s => fresh)
          return [ "#{fresh} = #{rewrite(slice(node.value), env)}\n", newenv ]
        end

        return [ "#{rewrite(slice(node), env)}\n", env ] unless node.is_a?(Prism::CallNode)

        name     = node.name
        receiver = node.receiver

        return [ "", env ] if name == :public

        if receiver
          return [ emit_leaf(node, offset, env), env ] if LEAF.include?(name)
          return [ emit_on(node, offset, env), env ]   if name == :on
          return [ emit_is(node, offset, env), env ]   if name == :is
          return [ emit_root(node, offset, env), env ] if name == :root
        end

        [ "#{rewrite(slice(node), env)}\n", env ]
      end

      ROUTING_METHODS = %i[get post put patch delete options head on is root].freeze

      def emit_leaf(call, offset, env)
        method   = call.name.to_s.upcase
        matchers = call.arguments&.arguments || []
        conds    = match_conditions(matchers, offset, terminal: true)
        conds << "r.request_method == #{method.inspect}"
        assigns  = capture_assignments(matchers, param_names(call), offset)

        body   = call.block&.body
        source = body ? rewrite(slice(body), env) : "nil"
        source = "#{assigns.join("\n")}\n#{source}" unless assigns.empty?

        <<~RUBY
          if #{conds.join(' && ')}
            return (begin
          #{indent(source, 4)}
            end)
          end
        RUBY
      end

      def emit_on(call, offset, env)
        emit_scope(call, offset, env, terminal: false)
      end

      def emit_is(call, offset, env)
        emit_scope(call, offset, env, terminal: true)
      end

      # Shared by `r.on` (prefix match) and `r.is` (terminal match). A scope
      # whose block is a plain expression must return it, or the dispatcher
      # would drop the response body; scopes that contain nested route calls
      # return through those leaves instead.
      def emit_scope(call, offset, env, terminal:)
        matchers = call.arguments&.arguments || []
        inner_at = offset + matchers.length
        body     = call.block&.body
        assigns  = capture_assignments(matchers, param_names(call), offset)
        conds    = match_conditions(matchers, offset, terminal: terminal)

        inner   = if body && !routing_body?(body)
          "return (begin\n#{indent(rewrite(slice(body), env), 2)}\nend)"
        elsif body
          emit_statements(body.body, inner_at, env.dup)
        else
          ""
        end
        content = assigns.empty? ? inner : "#{assigns.join("\n")}\n#{inner}"

        <<~RUBY
          if #{conds.join(' && ')}
          #{indent(content, 2)}
          end
        RUBY
      end

      # True when +body+ contains a nested route call (`r.on`, `r.is`, ...).
      def routing_body?(body)
        found = false
        Node.walk(body) do |node|
          next unless node.is_a?(Prism::CallNode)

          receiver = node.receiver
          next unless receiver.is_a?(Prism::LocalVariableReadNode) && receiver.name == :r

          found = true if ROUTING_METHODS.include?(node.name)
        end
        found
      end

      def emit_root(call, offset, env)
        body   = call.block&.body
        source = body ? rewrite(slice(body), env) : "nil"
        <<~RUBY
          if r.segments.length == #{offset} && r.request_method == "GET"
            return (begin
          #{indent(source, 4)}
            end)
          end
        RUBY
      end

      # Conditions that must hold for `matchers` to match at `offset`.
      # Terminal matchers (`r.is`, `r.get`, ...) must consume the rest of the
      # path; `r.on` only matches a prefix.
      def match_conditions(matchers, offset, terminal:)
        conds = []
        if terminal
          conds << "r.segments.length == #{offset + matchers.length}"
        elsif !matchers.empty?
          conds << "r.segments.length > #{offset + matchers.length - 1}"
        end

        matchers.each_with_index do |matcher, index|
          position = offset + index
          case matcher
          when Prism::StringNode, Prism::SymbolNode
            conds << "r.segments[#{position}] == #{Node.literal(matcher).inspect}"
          when Prism::ConstantReadNode
            conds << "r.segments[#{position}].match?(/\\A\\d+\\z/)" if matcher.name == :Integer
          end
        end
        conds
      end

      # Assignments that bind the block params to the segments captured by
      # `String`/`Integer` matchers, in order. Roda does not yield literal
      # matches, so only the non-literal matchers consume params.
      def capture_assignments(matchers, params, offset)
        assignments = []
        index       = 0

        matchers.each_with_index do |matcher, position|
          next unless matcher.is_a?(Prism::ConstantReadNode)

          name   = params[index]
          index += 1
          next unless name

          source = case matcher.name
          when :String  then "r.segments[#{offset + position}]"
          when :Integer then "r.segments[#{offset + position}].to_i"
          end
          assignments << "#{name} = #{source}" if source
        end
        assignments
      end

      def param_names(call)
        parameters = call.block&.parameters
        return [] unless parameters

        (parameters.parameters&.requireds || []).map { |node| node.name.to_s }
      end

      def indent(text, spaces)
        pad = " " * spaces
        text.to_s.split("\n", -1).map { |line| line.empty? ? line : "#{pad}#{line}" }.join("\n")
      end
    end
  end
end
