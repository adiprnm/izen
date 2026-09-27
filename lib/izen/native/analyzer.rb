# frozen_string_literal: true

require "prism"

module Izen
  module Native
    # Small helpers over Prism nodes.
    module Node
      module_function

      def slice(source, node)
        source[node.location.start_offset...node.location.end_offset]
      end

      def literal(node)
        case node
        when Prism::SymbolNode  then node.unescaped.to_sym
        when Prism::StringNode  then node.unescaped
        when Prism::IntegerNode then node.value
        when Prism::FloatNode   then node.value
        when Prism::TrueNode    then true
        when Prism::FalseNode   then false
        when Prism::NilNode     then nil
        when Prism::ArrayNode   then node.elements.map { |element| literal(element) }
        else node
        end
      end

      def constant_name(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode
          parent = node.parent ? constant_name(node.parent) : ""
          "#{parent}::#{node.name}"
        end
      end

      def keyword_hash(node)
        return {} unless node.is_a?(Prism::KeywordHashNode)

        result = {}
        node.elements.each do |assoc|
          next unless assoc.is_a?(Prism::AssocNode)

          key         = literal(assoc.key)
          result[key] = assoc.value
        end
        result
      end

      def walk(node, &block)
        return unless node

        yield node
        node.compact_child_nodes.each { |child| walk(child, &block) }
      end
    end

    Attribute = Struct.new(:name, :type, :required, :default_source, keyword_init: true)
    Field     = Struct.new(:name, :type, :required, :options, keyword_init: true)

    # Reads an Izen app's source and extracts the pieces the generator needs.
    class Analyzer
      TYPE_MAP = {
        "String" => :string, "Integer" => :integer, "Float" => :float,
        "Numeric" => :numeric, "Time" => :time, "Date" => :date,
        "DateTime" => :datetime, "Array" => :array, "Hash" => :hash,
        "TrueClass" => :boolean, "FalseClass" => :boolean, "Symbol" => :symbol
      }.freeze

      attr_reader :root

      def initialize(root)
        @root = root
      end

      def modules
        Dir[File.join(root, "app/*")].select { |path| File.directory?(path) }.map { |path| File.basename(path) }
      end

      def model_files
        Dir[File.join(root, "app/*/model.rb")].sort
      end

      def contract_files
        Dir[File.join(root, "app/*/contract.rb")].sort
      end

      def controller_files
        Dir[File.join(root, "app/*/*controller.rb")].sort
      end

      def repository_files
        Dir[File.join(root, "app/*/repository.rb")].sort
      end

      def view_files
        Dir[File.join(root, "views/**/*.erb")].sort
      end

      def lib_files
        Dir[File.join(root, "lib/**/*.rb")].sort
      end

      # --- models -----------------------------------------------------------

      def model(path)
        source      = File.read(path)
        tree        = Prism.parse(source).value
        klass       = find_class(tree)
        body        = klass.body
        module_name = enclosing_module(tree)

        attributes = []
        extra      = []

        body&.body&.each do |statement|
          if statement.is_a?(Prism::CallNode) && statement.name == :attribute && statement.receiver.nil?
            attributes << parse_attribute(statement, source)
          else
            extra << Node.slice(source, statement)
          end
        end

        {
          module:     module_name,
          class:      "Model",
          attributes: attributes,
          extra:      extra,
          requires:   top_level_requires(tree, source)
        }
      end

      def parse_attribute(call, source)
        args  = call.arguments.arguments
        name  = Node.literal(args[0])
        type  = type_symbol(args[1])
        opts  = Node.keyword_hash(args[2])

        required = opts.key?(:required) ? Node.literal(opts[:required]) : true
        default  = opts.key?(:default) ? Node.slice(source, opts[:default]) : "nil"

        Attribute.new(name: name, type: type, required: required, default_source: default)
      end

      # --- contracts --------------------------------------------------------

      def contract(path)
        source      = File.read(path)
        tree        = Prism.parse(source).value
        module_name = enclosing_module(tree)

        fields = []
        rules  = []

        Node.walk(tree) do |node|
          next unless node.is_a?(Prism::CallNode) && node.receiver.nil?

          case node.name
          when :params
            fields = params_fields(node, source)
          when :rule
            block = node.block&.body
            rules << Node.slice(source, block) if block
          end
        end

        { module: module_name, class: "Contract", fields: fields, rules: rules }
      end

      def params_fields(call, source)
        body = call.block&.body
        return [] unless body

        fields = []
        body.body.each do |statement|
          next unless statement.is_a?(Prism::CallNode)

          name = statement.name
          next unless name == :required || name == :optional

          args    = statement.arguments.arguments
          field   = Node.literal(args[0])
          type    = type_symbol(args[1])
          options = Node.keyword_hash(args[2])

          rendered                                  = {}
          rendered[:type]                           = type.inspect
          rendered[:required]                       = (name == :required).to_s
          options.each { |key, value| rendered[key] = Node.slice(source, value) }

          fields << Field.new(name: field, type: type, required: name == :required, options: rendered)
        end
        fields
      end

      # --- render locals ----------------------------------------------------

      # template name => union of local variable names passed by controllers.
      def render_locals
        result = {}
        controller_files.each do |path|
          source = File.read(path)
          tree   = Prism.parse(source).value
          Node.walk(tree) do |node|
            next unless node.is_a?(Prism::CallNode) && node.name == :render && node.arguments

            args     = node.arguments.arguments
            template = args[0]
            next unless template.is_a?(Prism::StringNode)

            key           = template.unescaped
            result[key] ||= []
            args[1..].each do |arg|
              next unless arg.is_a?(Prism::KeywordHashNode)

              arg.elements.each do |assoc|
                next unless assoc.is_a?(Prism::AssocNode)

                name = Node.literal(assoc.key).to_s
                result[key] << name unless result[key].include?(name)
              end
            end
          end
        end
        result
      end

      # --- routes + app class ----------------------------------------------

      def app_tree
        Prism.parse(File.read(File.join(root, "app.rb"))).value
      end

      def route_block
        source = File.read(File.join(root, "app.rb"))
        tree   = Prism.parse(source).value
        block  = nil
        Node.walk(tree) do |node|
          if node.is_a?(Prism::CallNode) && node.name == :route && node.receiver.nil?
            block = node.block
          end
        end
        [ block, source ]
      end

      # The App class body, minus the `route do ... end` call: helper methods,
      # constants and includes that the generated App should keep.
      def app_helper_source
        source = File.read(File.join(root, "app.rb"))
        tree   = Prism.parse(source).value
        klass  = find_class(tree)
        return [] unless klass&.body

        klass.body.body.filter_map do |statement|
          next if statement.is_a?(Prism::CallNode) && statement.name == :route && statement.receiver.nil?
          next if statement.is_a?(Prism::DefNode) && statement.name == :initialize

          Node.slice(source, statement)
        end
      end

      # Top-level `require` / `require_relative` lines from app.rb.
      def app_requires
        source = File.read(File.join(root, "app.rb"))
        tree   = Prism.parse(source).value
        top_level_requires(tree, source)
      end

      # Names of the helper methods declared directly on the App class. The
      # generator emits explicit delegators for them on Base::Controller,
      # because Spinel does not dispatch undefined methods to method_missing.
      def app_helper_methods
        source = File.read(File.join(root, "app.rb"))
        tree   = Prism.parse(source).value
        klass  = find_class(tree)
        return [] unless klass&.body

        klass.body.body.filter_map do |statement|
          next unless statement.is_a?(Prism::DefNode)
          next if statement.name == :initialize

          statement.name.to_s
        end
      end

      # --- helpers ----------------------------------------------------------

      def type_symbol(node)
        case node
        when Prism::SymbolNode then node.unescaped.to_sym
        when Prism::ConstantReadNode then TYPE_MAP[node.name.to_s] || node.name.to_s.downcase.to_sym
        else :object
        end
      end

      def find_class(tree)
        klass                            = nil
        Node.walk(tree) { |node| klass ||= node if node.is_a?(Prism::ClassNode) }
        klass
      end

      def enclosing_module(tree)
        node                                 = nil
        Node.walk(tree) { |candidate| node ||= candidate if candidate.is_a?(Prism::ModuleNode) }
        node ? Node.constant_name(node.constant_path).split("::").last : nil
      end

      # Module name for any file (used for repositories).
      def module_of(path)
        enclosing_module(Prism.parse(File.read(path)).value)
      end

      def top_level_requires(tree, source)
        requires = []
        tree.statements.body.each do |statement|
          if statement.is_a?(Prism::CallNode) && %i[require require_relative].include?(statement.name)
            requires << Node.slice(source, statement)
          end
        end
        requires
      end
    end
  end
end
