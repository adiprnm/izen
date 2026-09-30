# frozen_string_literal: true

require "prism"

module Izen
  module Native
    # Small helpers over Prism nodes.
    module Node
      module_function

      # Prism reports BYTE offsets; `String#[]` indexes characters, which drift
      # apart on a non-ASCII source (the app's HTML/Indonesian text). Slice by
      # bytes so the extracted source is exact.
      def slice(source, node)
        start = node.location.start_offset
        source.byteslice(start, node.location.end_offset - start)
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

      # Every file that declares a `< Base::Model` subclass (usually
      # `app/<mod>/model.rb`, but the app may ship extra model classes such as
      # `orders/order_item.rb`). They are regenerated with explicit attribute
      # readers, so the originals are not copied.
      def model_files
        Dir[File.join(root, "app/**/*.rb")]
          .reject { |path| path.end_with?("_test.rb") || File.basename(path) == "test_helper.rb" }
          .select { |path| model_definition?(path) }
          .sort
      end

      def model_definition?(path)
        Node.walk(Prism.parse(File.read(path)).value) do |node|
          next unless node.is_a?(Prism::ClassNode) && node.superclass

          name = Node.constant_name(node.superclass)
          return true if name && (name == "Model" || name.end_with?("::Model"))
        end
        false
      end

      def contract_files
        Dir[File.join(root, "app/*/contract.rb")].sort
      end

      # Controllers, including nested ones (`app/admin/posts/controller.rb`).
      def controller_files
        Dir[File.join(root, "app/**/*controller.rb")]
          .reject { |path| path.end_with?("_test.rb") }
          .sort
      end

      def repository_files
        Dir[File.join(root, "app/**/repository.rb")].sort
      end

      # Everything else under app/ that the domain code needs: helper modules,
      # services, value objects, mailers, ... Models/contracts are regenerated
      # from their declarations, repositories and controllers are copied by
      # their own lists, and colocated tests are skipped.
      def support_files
        models = model_files
        Dir[File.join(root, "app/**/*.rb")].sort.reject do |path|
          base = File.basename(path)
          base == "contract.rb" || base == "repository.rb" ||
            base.end_with?("controller.rb") || base.end_with?("_test.rb") ||
            base == "test_helper.rb" || models.include?(path)
        end
      end

      # Views live next to the code they belong to: `app/<mod>/<view>.erb` for
      # module views and `app/layout.erb` (or `app/layouts/*.erb`) for layouts.
      def view_files
        Dir[File.join(root, "app/**/*.erb")].sort
      end

      def lib_files
        Dir[File.join(root, "lib/**/*.rb")].sort
      end

      # --- models -----------------------------------------------------------

      # Every `Base::Model` subclass in the file. A single file may declare
      # more than one (e.g. `Category::Model` plus `Category::Uncategorized`),
      # so the generator emits them all.
      def models(path)
        source      = File.read(path)
        tree        = Prism.parse(source).value
        module_name = enclosing_module(tree)
        requires    = top_level_requires(tree, source)

        model_classes(tree).map do |klass|
          attributes = []
          extra      = []

          klass.body&.body&.each do |statement|
            if statement.is_a?(Prism::CallNode) && statement.name == :attribute && statement.receiver.nil?
              attributes << parse_attribute(statement, source)
            else
              extra << Node.slice(source, statement)
            end
          end

          {
            module:     module_name,
            class:      klass.name.to_s,
            attributes: attributes,
            extra:      extra,
            requires:   requires
          }
        end
      end

      def model(path)
        models(path).first
      end

      def model_classes(tree)
        classes = []
        Node.walk(tree) { |node| classes << node if node.is_a?(Prism::ClassNode) }
        classes.select { |klass| model_class?(klass) }
      end

      def model_class?(klass)
        superclass = klass.superclass
        return false unless superclass

        name = Node.constant_name(superclass).to_s
        name == "Model" || name.end_with?("::Model")
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

      # template name => union of local variable names passed by controllers
      # and helpers: keyword args, a literal hash, a local hash variable
      # (`locals = { ... }; render(tpl, locals)`), or a helper that returns a
      # hash (`render(tpl, settings_locals(tab))`).
      def render_locals
        result = {}
        (controller_files + support_files + lib_files).uniq.each do |path|
          collect_render_locals(File.read(path), result)
        end
        result
      end

      # Merges the `render`/`view` locals found in one Ruby source into
      # +result+ (template => local names). The generator also feeds compiled
      # ERB sources here, so a partial reached from a template
      # (`view(".../_form", locals: {...})`) gets its locals too.
      def collect_render_locals(source, result)
          tree    = Prism.parse(source).value
          hashes  = hash_local_keys(tree)
          methods = method_hash_keys(tree)

          Node.walk(tree) do |node|
            next unless node.is_a?(Prism::CallNode) && %i[render view partial
fragment].include?(node.name) && node.arguments

            args     = node.arguments.arguments
            template = args[0]
            next unless template.is_a?(Prism::StringNode)

            key           = template.unescaped
            result[key] ||= []
            add           = ->(name) { result[key] << name unless result[key].include?(name) }

            args[1..].each do |arg|
              case arg
              when Prism::LocalVariableReadNode
                (hashes[arg.name.to_s] || []).each { |name| add.call(name) }
              when Prism::CallNode
                if arg.receiver.nil? || arg.receiver.is_a?(Prism::SelfNode)
                  (methods[arg.name.to_s] || []).each { |name| add.call(name) }
                end
              when Prism::HashNode
                hash_node_keys(arg).each { |name| add.call(name) }
              when Prism::KeywordHashNode
                arg.elements.each do |assoc|
                  next unless assoc.is_a?(Prism::AssocNode)

                  name = Node.literal(assoc.key).to_s
                  if name == "locals" && assoc.value.is_a?(Prism::HashNode)
                    hash_node_keys(assoc.value).each { |local| add.call(local) }
                  else
                    add.call(name)
                  end
                end
              end
            end
          end
        result
      end

      # Keys of hash-valued locals built in a file: `locals = { a: ..., b: ... }`
      # plus later `locals[:c] = ...` additions. name => [keys].
      def hash_local_keys(tree)
        keys = Hash.new { |hash, name| hash[name] = [] }
        add  = ->(name, key) { keys[name] << key unless keys[name].include?(key) }

        Node.walk(tree) do |node|
          case node
          when Prism::LocalVariableWriteNode
            next unless node.value.is_a?(Prism::HashNode)

            name = node.name.to_s
            hash_node_keys(node.value).each { |key| add.call(name, key) }
          when Prism::CallNode
            next unless node.name == :[]= && node.receiver.is_a?(Prism::LocalVariableReadNode)

            args = node.arguments&.arguments || []
            add.call(node.receiver.name.to_s, Node.literal(args[0]).to_s)
          end
        end
        keys
      end

      # Method name => keys of the hash it returns (a literal hash as its last
      # expression or explicit `return`), for helpers that build render locals.
      def method_hash_keys(tree)
        keys = {}
        Node.walk(tree) do |node|
          next unless node.is_a?(Prism::DefNode)

          keys[node.name.to_s] = hash_node_keys(returned_hash(node.body))
        end
        keys
      end

      def returned_hash(body)
        return nil unless body.is_a?(Prism::StatementsNode)

        case (last = body.body.last)
        when Prism::HashNode   then last
        when Prism::ReturnNode then last.arguments&.arguments&.first
        end
      end

      def hash_node_keys(node)
        return [] unless node.is_a?(Prism::HashNode)

        node.elements.filter_map do |element|
          Node.literal(element.key).to_s if element.is_a?(Prism::AssocNode)
        end
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

      # The App class body, minus the pieces the generated runtime supplies
      # itself: only helper method definitions and constants are kept. The
      # `route do ... end` block is lowered separately, and `plugin`/`include`
      # calls are handled by the generated App class.
      def app_helper_source
        source = File.read(File.join(root, "app.rb"))
        tree   = Prism.parse(source).value
        klass  = find_class(tree)
        return [] unless klass&.body

        klass.body.body.filter_map do |statement|
          case statement
          when Prism::DefNode
            next if statement.name == :initialize || statement.receiver

            Node.slice(source, statement)
          when Prism::ConstantWriteNode
            Node.slice(source, statement)
          end
        end
      end

      # Top-level constants and modules in app.rb (ROUTES, PERIOD_OPTIONS,
      # Persistable, …) that the copied helper modules, models and views
      # reference.
      def app_constants
        source = File.read(File.join(root, "app.rb"))
        tree   = Prism.parse(source).value
        tree.statements.body.filter_map do |statement|
          case statement
          when Prism::ConstantWriteNode, Prism::ModuleNode
            Node.slice(source, statement)
          end
        end
      end

      # Top-level `require` / `require_relative` lines from app.rb.
      def app_requires
        source = File.read(File.join(root, "app.rb"))
        tree   = Prism.parse(source).value
        top_level_requires(tree, source)
      end

      # Helper methods the App exposes: the `def`s directly on the App class
      # body plus every method of the modules it `include`s (and, recursively,
      # the modules those include). Each entry carries the parameter list and
      # the forwarding arguments, so the generated delegators on
      # Base::Controller match the target's arity exactly (Spinel binds calls
      # statically and refuses a mismatched splat).
      def app_helper_methods
        methods = app_class_defs
        app_includes.each { |name| methods.concat(module_instance_methods(name)) }

        seen                                          = {}
        methods.each { |method| seen[method[:name]] ||= method }
        seen.values
      end

      # `def`s written directly on the App class body.
      def app_class_defs
        tree   = app_tree
        source = File.read(File.join(root, "app.rb"))
        klass  = find_class(tree)
        return [] unless klass&.body

        klass.body.body.filter_map do |statement|
          next unless statement.is_a?(Prism::DefNode)
          next if statement.name == :initialize
          next if statement.receiver

          signature(statement, source)
        end
      end

      # Module constant paths named by `include ...` inside the App class body
      # (e.g. ["AppHelpers", "Auth", "Posts::Helper"]).
      def app_includes
        tree  = app_tree
        klass = find_class(tree)
        return [] unless klass&.body

        klass.body.body.flat_map do |statement|
          next [] unless statement.is_a?(Prism::CallNode) && statement.name == :include && statement.receiver.nil?

          (statement.arguments&.arguments || []).filter_map do |argument|
            if argument.is_a?(Prism::ConstantReadNode) || argument.is_a?(Prism::ConstantPathNode)
              Node.constant_name(argument)
            end
          end
        end
      end

      # Resolve a module constant path to its instance method names, following
      # nested `include`s. Falls back to [] when the module is not defined in
      # the app source (runtime modules such as Helpers).
      def module_instance_methods(name, seen = [])
        return [] if name.nil? || seen.include?(name)

        definition = module_registry[name]
        return [] unless definition

        nested = definition[:includes].flat_map { |nested_name| module_instance_methods(nested_name, seen + [ name ]) }
        definition[:methods] + nested
      end

      # Constant path => { methods: [...], includes: [...] } for every module
      # declared under app/ or lib/ (shared helper mixins live in lib/).
      def module_registry
        @module_registry ||= begin
          registry = {}
          [ "app/**/*.rb", "lib/**/*.rb" ].each do |glob|
            Dir[File.join(root, glob)]
              .reject { |path| path.end_with?("_test.rb") || File.basename(path) == "test_helper.rb" }
              .each do |path|
                source = File.read(path)
                collect_modules(Prism.parse(source).value, "", registry, source)
              end
          end
          registry
        end
      end

      def collect_modules(node, prefix, registry, source)
        case node
        when Prism::ModuleNode
          name = Node.constant_name(node.constant_path)
          full = prefix.empty? ? name : "#{prefix}::#{name}"

          methods  = []
          includes = []
          (node.body&.body || []).each do |statement|
            if statement.is_a?(Prism::DefNode) && statement.receiver.nil?
              methods << signature(statement, source)
            elsif statement.is_a?(Prism::CallNode) && statement.name == :include && statement.receiver.nil?
              (statement.arguments&.arguments || []).each do |argument|
                if argument.is_a?(Prism::ConstantReadNode) || argument.is_a?(Prism::ConstantPathNode)
                  includes << Node.constant_name(argument)
                end
              end
            end
          end
          registry[full] = { methods: methods, includes: includes }

          (node.body&.body || []).each { |child| collect_modules(child, full, registry, source) }
        when Prism::ClassNode
          name = Node.constant_name(node.constant_path)
          full = prefix.empty? ? name : "#{prefix}::#{name}"
          (node.body&.body || []).each { |child| collect_modules(child, full, registry, source) }
        else
          node.compact_child_nodes.each { |child| collect_modules(child, prefix, registry, source) }
        end
      end

      # A def's name plus the parameter list and the forwarding arguments that
      # reproduce it at a call site.
      def signature(def_node, source)
        parameters = def_node.parameters
        name       = def_node.name.to_s
        return { name: name, params: "", forward: "" } unless parameters

        parts   = parameters.compact_child_nodes
        params  = parts.map { |part| Node.slice(source, part) }.join(", ")
        forward = parts.filter_map do |part|
          case part
          when Prism::RequiredParameterNode, Prism::OptionalParameterNode, Prism::MultiTargetNode
            part.name.to_s
          when Prism::RequiredKeywordParameterNode, Prism::OptionalKeywordParameterNode
            # Keyword parameters must be forwarded as keywords, not positionally.
            "#{part.name}: #{part.name}"
          when Prism::RestParameterNode          then "*#{part.name}"
          when Prism::KeywordRestParameterNode   then "**#{part.name}"
          when Prism::BlockParameterNode         then "&#{part.name}"
          end
        end.join(", ")

        { name: name, params: params, forward: forward }
      end

      # True when the App configures Roda's render plugin with `escape: true`
      # (`plugin :render, ..., escape: true`). The generated view code must use
      # the same Erubi layout settings, or `<%=` and `<%==` swap meaning.
      def view_escape?
        Node.literal(view_options[:escape]) == true || Node.literal(view_options[:escape_html]) == true
      end

      # The layout the app's render plugin applies by default
      # (`plugin :render, layout: "layouts/application"`), or nil.
      def view_layout
        layout = Node.literal(view_options[:layout])
        layout.is_a?(String) ? layout : nil
      end

      # Keyword options of the App's `plugin :render, ...` call.
      def view_options
        @view_options ||= begin
          tree    = app_tree
          klass   = find_class(tree)
          options = {}
          (klass&.body&.body || []).each do |statement|
            next unless statement.is_a?(Prism::CallNode) && statement.name == :plugin && statement.receiver.nil?

            args = statement.arguments&.arguments || []
            next unless Node.literal(args[0]) == :render

            options = Node.keyword_hash(args[1] || args[2])
          end
          options
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

      # The host application class. Prefer the class that subclasses the Izen
      # application (`class App < Izen::Application`); fall back to the first
      # class when there is no such subclass (e.g. plain Roda apps). Without
      # this, a base class defined earlier in app.rb (such as
      # `ApplicationController`) would be mistaken for the app class.
      def find_class(tree)
        classes = []
        Node.walk(tree) { |node| classes << node if node.is_a?(Prism::ClassNode) }
        classes.find { |klass| application_class?(klass) } || classes.first
      end

      def application_class?(klass)
        superclass = klass.superclass
        return false unless superclass

        Node.constant_name(superclass).to_s.end_with?("Application")
      end

      # The superclass the copied controllers use (e.g. "ApplicationController").
      # The generated runtime exposes the base as Base::Controller, so the
      # generator aliases the app's name to it for the copied subclasses.
      def controller_base_class
        path = controller_files.first
        return nil unless path

        klass                                                          = nil
        Node.walk(Prism.parse(File.read(path)).value) { |node| klass ||= node if node.is_a?(Prism::ClassNode) }
        return nil unless klass&.superclass

        name = Node.constant_name(klass.superclass).to_s
        return nil if name.empty? || name == "Base::Controller" || name == "Izen::Base::Controller"

        name
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
