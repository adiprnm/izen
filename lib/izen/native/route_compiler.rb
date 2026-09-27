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

      def emit_leaf(call, offset, env)
        method = call.name.to_s.upcase
        args   = call.arguments&.arguments || []
        path   = args[0]

        conds = []
        if path.is_a?(Prism::StringNode) || path.is_a?(Prism::SymbolNode)
          conds << "r.segments.length == #{offset + 1}"
          conds << "r.segments[#{offset}] == #{Node.literal(path).inspect}"
        else
          conds << "r.segments.length == #{offset}"
        end
        conds << "r.request_method == #{method.inspect}"

        body   = call.block&.body
        source = body ? rewrite(slice(body), env) : "nil"

        <<~RUBY
          if #{conds.join(' && ')}
            return (begin
          #{indent(source, 4)}
            end)
          end
        RUBY
      end

      def emit_on(call, offset, env)
        segment = (call.arguments&.arguments || [])[0]
        body    = call.block&.body
        inner   = body ? emit_statements(body.body, offset + 1, env.dup) : ""

        if segment.is_a?(Prism::ConstantReadNode) && segment.name == :Integer
          param = block_param(call)
          cond  = "r.segments.length > #{offset} && r.segments[#{offset}].match?(/\\A\\d+\\z/)"
          <<~RUBY
            if #{cond}
              #{param} = r.segments[#{offset}].to_i
            #{indent(inner, 2)}
            end
          RUBY
        else
          cond = "r.segments.length > #{offset} && r.segments[#{offset}] == #{Node.literal(segment).inspect}"
          <<~RUBY
            if #{cond}
            #{indent(inner, 2)}
            end
          RUBY
        end
      end

      def emit_is(call, offset, env)
        body  = call.block&.body
        inner = body ? emit_statements(body.body, offset, env.dup) : ""
        <<~RUBY
          if r.segments.length == #{offset}
          #{indent(inner, 2)}
          end
        RUBY
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

      def block_param(call)
        parameters = call.block&.parameters
        return "id" unless parameters

        node = parameters.parameters&.requireds&.first
        node ? node.name.to_s : "id"
      end

      def indent(text, spaces)
        pad = " " * spaces
        text.to_s.split("\n", -1).map { |line| line.empty? ? line : "#{pad}#{line}" }.join("\n")
      end
    end
  end
end
