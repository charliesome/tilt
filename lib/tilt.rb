module Tilt
  VERSION = '0.6'

  @template_mappings = {}

  # Hash of template path pattern => template implementation class mappings.
  def self.mappings
    @template_mappings
  end

  # Register a template implementation by file extension.
  def self.register(ext, template_class)
    ext = ext.to_s.sub(/^\./, '')
    mappings[ext.downcase] = template_class
  end

  # Create a new template for the given file using the file's extension
  # to determine the the template mapping.
  def self.new(file, line=nil, options={}, &block)
    if template_class = self[file]
      template_class.new(file, line, options, &block)
    else
      fail "No template engine registered for #{File.basename(file)}"
    end
  end

  # Lookup a template class for the given filename or file
  # extension. Return nil when no implementation is found.
  def self.[](file)
    if @template_mappings.key?(pattern = file.to_s.downcase)
      @template_mappings[pattern]
    elsif @template_mappings.key?(pattern = File.basename(pattern))
      @template_mappings[pattern]
    else
      while !pattern.empty?
        if @template_mappings.key?(pattern)
          return @template_mappings[pattern]
        else
          pattern = pattern.sub(/^[^.]*\.?/, '')
        end
      end
      nil
    end
  end

  # Default site for compiled template methods. Mixing this module
  # into scope objects drastically improves performance for source
  # generating templates like ERB, Erubis, and Builder.
  module CompiledTemplates
  end

  # Base class for template implementations. Subclasses must implement
  # the #prepare method and one of the #evaluate or #template_source
  # methods.
  class Template
    # Template source; loaded from a file or given directly.
    attr_reader :data

    # The name of the file where the template data was loaded from.
    attr_reader :file

    # The line number in #file where template data was loaded from.
    attr_reader :line

    # A Hash of template engine specific options. This is passed directly
    # to the underlying engine and is not used by the generic template
    # interface.
    attr_reader :options

    # A module where compiled methods should be created.
    attr_reader :compile_site

    # Create a new template with the file, line, and options specified. By
    # default, template data is read from the file specified. When a block
    # is given, it should read template data and return as a String. When
    # file is nil, a block is required.
    #
    # For source generating templates, passing a module as the compile_site
    # argument enables template compilation. This module must also be mixed
    # into objects passed in the scope argument in order for template
    # compilation to function properly. If no compile_site is given, templates
    # are evaluated from source each time they're rendered.
    def initialize(file=nil, line=1, options={}, compile_site=nil, &block)
      raise ArgumentError, "file or block required" if file.nil? && block.nil?
      compile_site, options = options, {} if options.is_a?(Module)
      options, line = line, 1 if line.is_a?(Hash)
      @file = file
      @line = line || 1
      @options = options || {}
      @compile_site = compile_site
      @reader = block || lambda { |t| File.read(file) }
      @data = nil

      if !self.class.engine_initialized
        initialize_engine
        self.class.engine_initialized = true
      end

      @data = @reader.call(self)
      prepare
    end

    # Called once and only once for each template subclass the first time
    # the template class is initialized. This should be used to require the
    # underlying template library and perform any initial setup.
    def initialize_engine
    end
    @engine_initialized = false
    class << self ; attr_accessor :engine_initialized ; end

    # Render the template in the given scope with the locals specified. If a
    # block is given, it is typically available within the template via
    # +yield+.
    def render(scope=Object.new, locals={}, &block)
      evaluate scope, locals || {}, &block
    end

    # The basename of the template file.
    def basename(suffix='')
      File.basename(file, suffix) if file
    end

    # The template file's basename with all extensions chomped off.
    def name
      basename.split('.', 2).first if basename
    end

    # The filename used in backtraces to describe the template.
    def eval_file
      file || '(__TEMPLATE__)'
    end

  protected
    # Do whatever preparation is necessary to setup the underlying template
    # engine. Called immediately after template data is loaded. Instance
    # variables set in this method are available when #evaluate is called.
    #
    # Subclasses must provide an implementation of this method.
    def prepare
      if respond_to?(:compile!)
        # backward compat with tilt < 0.6; just in case
        warn 'Tilt::Template#compile! is deprecated; implement #prepare instead.'
        compile!
      else
        raise NotImplementedError
      end
    end

    # Process the template and return the result. When a compile_site is
    # set, compiles the template to a method and reuses given identical
    # locals keys. When no compile_site is set or the scope object
    # does not mix in the compile_site module, the template source is
    # evaluated with instance_eval. In any case, template executation
    # is guaranteed to be performed in the scope object with the locals
    # specified and with support for yielding to the block.
    def evaluate(scope, locals, &block)
      if compile_site
        method_name = compiled_method_name(locals)
        if scope.respond_to?(method_name)
          # fast path compiled method already defined
          scope.send method_name, locals, &block
        else
          # compile and try to run; disable compile_site for this template
          # if scope doesn't have the module mixed in properly.
          compile_template_method(method_name, locals)
          if scope.respond_to?(method_name)
            scope.send method_name, locals, &block
          else
            # XXX maybe we should issue a warning here
            @compile_site = nil
            evaluate(scope, locals, &block)
          end
        end
      else
        source, offset = local_assignment_code(locals)
        source = [source, template_source].join("\n")
        scope.instance_eval source, eval_file, line - offset
      end
    end

    # Return a string containing the (Ruby) source code for the template. The
    # default Template#evaluate implementation requires this method be
    # defined and guarantees correct file/line handling, custom scopes, and
    # support for template compilation when the compile_site attribute is set.
    def template_source
      raise NotImplementedError
    end

  private
    def local_assignment_code(locals)
      return ['', 1] if locals.empty?
      source = locals.collect { |k,v| "#{k} = locals[:#{k}]" }
      [source.join("\n"), source.length]
    end

    def compiled_method_name(locals)
      "__tilt_#{object_id}_#{locals.keys.hash}"
    end

    def compile_template_method(method_name, locals)
      source, offset = local_assignment_code(locals)
      source = [source, template_source].join("\n")
      offset += 1
      compile_site.module_eval <<-RUBY, eval_file, line - offset
        def #{method_name}(locals)
          #{source}
        end
      RUBY
    end

    def require_template_library(name)
      if Thread.list.size > 1
        warn "WARN: tilt autoloading '#{name}' in a non thread-safe way; " +
             "explicit require '#{name}' suggested."
      end
      require name
    end
  end

  # Extremely simple template cache implementation. Calling applications
  # create a Tilt::Cache instance and use #fetch with any set of hashable
  # arguments (such as those to Tilt.new):
  #   cache = Tilt::Cache.new
  #   cache.fetch(path, line, options) { Tilt.new(path, line, options) }
  #
  # Subsequent invocations return the already loaded template object.
  class Cache
    def initialize
      @cache = {}
    end

    def fetch(*key)
      @cache[key] ||= yield
    end

    def clear
      @cache = {}
    end
  end


  # Template Implementations ================================================


  # The template source is evaluated as a Ruby string. The #{} interpolation
  # syntax can be used to generated dynamic output.
  class StringTemplate < Template
    def prepare
      @code = "%Q{#{data}}"
    end

    def template_source
      @code
    end
  end
  register 'str', StringTemplate


  # ERB template implementation. See:
  # http://www.ruby-doc.org/stdlib/libdoc/erb/rdoc/classes/ERB.html
  class ERBTemplate < Template
    def initialize_engine
      require_template_library 'erb' unless defined? ::ERB
    end

    def prepare
      @engine = ::ERB.new(data, options[:safe], options[:trim], '@_out_buf')
    end

    def template_source
      @engine.src
    end

    def evaluate(scope, locals, &block)
      original_out_buf =
        scope.instance_variables.any? { |var| var.to_sym == :@_out_buf } &&
        scope.instance_variable_get(:@_out_buf)

      super

      output = scope.instance_variable_get(:@_out_buf)
      scope.instance_variable_set(:@_out_buf, original_out_buf)
      output
    end

  private

    # ERB generates a line to specify the character coding of the generated
    # source in 1.9. Account for this in the line offset.
    if RUBY_VERSION >= '1.9.0'
      def local_assignment_code(locals)
        source, offset = super
        [source, offset + 1]
      end
    end
  end
  %w[erb rhtml].each { |ext| register ext, ERBTemplate }


  # Erubis template implementation. See:
  # http://www.kuwata-lab.com/erubis/
  class ErubisTemplate < ERBTemplate
    def initialize_engine
      require_template_library 'erubis' unless defined? ::Erubis
    end

    def prepare
      Erubis::Eruby.class_eval(%Q{def add_preamble(src) src << "@_out_buf = _buf = '';" end})
      @engine = ::Erubis::Eruby.new(data, options)
    end

  private

    # Erubis doesn't have ERB's line-off-by-one under 1.9 problem. Override
    # and adjust back.
    if RUBY_VERSION >= '1.9.0'
      def local_assignment_code(locals)
        source, offset = super
        [source, offset - 1]
      end
    end
  end
  register 'erubis', ErubisTemplate


  # Haml template implementation. See:
  # http://haml.hamptoncatlin.com/
  class HamlTemplate < Template
    def initialize_engine
      require_template_library 'haml' unless defined? ::Haml::Engine
    end

    def prepare
      @engine = ::Haml::Engine.new(data, haml_options)
    end

    def evaluate(scope, locals, &block)
      @engine.render(scope, locals, &block)
    end

  private
    def haml_options
      options.merge(:filename => eval_file, :line => line)
    end
  end
  register 'haml', HamlTemplate


  # Sass template implementation. See:
  # http://haml.hamptoncatlin.com/
  #
  # Sass templates do not support object scopes, locals, or yield.
  class SassTemplate < Template
    def initialize_engine
      require_template_library 'sass' unless defined? ::Sass::Engine
    end

    def prepare
      @engine = ::Sass::Engine.new(data, sass_options)
    end

    def evaluate(scope, locals, &block)
      @engine.render
    end

  private
    def sass_options
      options.merge(:filename => eval_file, :line => line)
    end
  end
  register 'sass', SassTemplate


  # Lessscss template implementation. See:
  # http://lesscss.org/
  #
  # Less templates do not support object scopes, locals, or yield.
  class LessTemplate < Template
    def initialize_engine
      require_template_library 'less' unless defined? ::Less::Engine
    end

    def prepare
      @engine = ::Less::Engine.new(data)
    end

    def evaluate(scope, locals, &block)
      @engine.to_css
    end
  end
  register 'less', LessTemplate

  # Builder template implementation. See:
  # http://builder.rubyforge.org/
  class BuilderTemplate < Template
    def initialize_engine
      require_template_library 'builder' unless defined?(::Builder)
    end

    def prepare
    end

    def evaluate(scope, locals, &block)
      xml = ::Builder::XmlMarkup.new(:indent => 2)
      if data.respond_to?(:to_str)
        locals[:xml] = xml
        super(scope, locals, &block)
      elsif data.kind_of?(Proc)
        data.call(xml)
      end
      xml.target!
    end

    def template_source
      data.to_str
    end
  end
  register 'builder', BuilderTemplate


  # Liquid template implementation. See:
  # http://liquid.rubyforge.org/
  #
  # Liquid is designed to be a *safe* template system and threfore
  # does not provide direct access to execuatable scopes. In order to
  # support a +scope+, the +scope+ must be able to represent itself
  # as a hash by responding to #to_h. If the +scope+ does not respond
  # to #to_h it will be ignored.
  #
  # LiquidTemplate does not support yield blocks.
  #
  # It's suggested that your program require 'liquid' at load
  # time when using this template engine.
  class LiquidTemplate < Template
    def initialize_engine
      require_template_library 'liquid' unless defined? ::Liquid::Template
    end

    def prepare
      @engine = ::Liquid::Template.parse(data)
    end

    def evaluate(scope, locals, &block)
      locals = locals.inject({}){ |h,(k,v)| h[k.to_s] = v ; h }
      if scope.respond_to?(:to_h)
        scope  = scope.to_h.inject({}){ |h,(k,v)| h[k.to_s] = v ; h }
        locals = scope.merge(locals)
      end
      locals['yield'] = block.nil? ? '' : yield
      locals['content'] = locals['yield']
      @engine.render(locals)
    end
  end
  register 'liquid', LiquidTemplate


  # Discount Markdown implementation. See:
  # http://github.com/rtomayko/rdiscount
  #
  # RDiscount is a simple text filter. It does not support +scope+ or
  # +locals+. The +:smart+ and +:filter_html+ options may be set true
  # to enable those flags on the underlying RDiscount object.
  class RDiscountTemplate < Template
    def flags
      [:smart, :filter_html].select { |flag| options[flag] }
    end

    def initialize_engine
      require_template_library 'rdiscount' unless defined? ::RDiscount
    end

    def prepare
      @engine = RDiscount.new(data, *flags)
    end

    def evaluate(scope, locals, &block)
      @engine.to_html
    end
  end
  register 'markdown', RDiscountTemplate
  register 'mkd', RDiscountTemplate
  register 'md', RDiscountTemplate


  # RedCloth implementation. See:
  # http://redcloth.org/
  class RedClothTemplate < Template
    def initialize_engine
      require_template_library 'redcloth' unless defined? ::RedCloth
    end

    def prepare
      @engine = RedCloth.new(data)
    end

    def evaluate(scope, locals, &block)
      @engine.to_html
    end
  end
  register 'textile', RedClothTemplate


  # Mustache is written and maintained by Chris Wanstrath. See:
  # http://github.com/defunkt/mustache
  #
  # When a scope argument is provided to MustacheTemplate#render, the
  # instance variables are copied from the scope object to the Mustache
  # view.
  class MustacheTemplate < Template
    attr_reader :engine

    def initialize_engine
      require_template_library 'mustache' unless defined? ::Mustache
    end

    def prepare
      Mustache.view_namespace = options[:namespace]
      Mustache.view_path = options[:view_path] || options[:mustaches]
      @engine = options[:view] || Mustache.view_class(name)
      options.each do |key, value|
        next if %w[view view_path namespace mustaches].include?(key.to_s)
        @engine.send("#{key}=", value) if @engine.respond_to? "#{key}="
      end
    end

    def evaluate(scope=nil, locals={}, &block)
      instance = @engine.new

      # copy instance variables from scope to the view
      scope.instance_variables.each do |name|
        instance.instance_variable_set(name, scope.instance_variable_get(name))
      end

      # locals get added to the view's context
      locals.each do |local, value|
        instance[local] = value
      end

      # if we're passed a block it's a subview. Sticking it in yield
      # lets us use {{yield}} in layout.html to render the actual page.
      instance[:yield] = block.call if block

      instance.template = data unless instance.compiled?

      instance.to_html
    end
  end
  register 'mustache', MustacheTemplate

  # RDoc template. See:
  # http://rdoc.rubyforge.org/
  #
  # It's suggested that your program require 'rdoc/markup' and
  # 'rdoc/markup/to_html' at load time when using this template
  # engine.
  class RDocTemplate < Template
    def initialize_engine
      unless defined?(::RDoc::Markup)
        require_template_library 'rdoc/markup'
        require_template_library 'rdoc/markup/to_html'
      end
    end

    def prepare
      markup = RDoc::Markup::ToHtml.new
      @engine = markup.convert(data)
    end

    def evaluate(scope, locals, &block)
      @engine.to_s
    end
  end
  register 'rdoc', RDocTemplate

  # CoffeeScript info:
  # http://jashkenas.github.com/coffee-script/
  class CoffeeTemplate < Template
    def initialize_engine
      require_template_library 'coffee-script' unless defined? ::CoffeeScript
    end

    def prepare
      @engine = ::CoffeeScript::compile(data, options)
    end

    def evaluate(scope, locals, &block)
      @engine
    end
  end
  register 'coffee', CoffeeTemplate
end
