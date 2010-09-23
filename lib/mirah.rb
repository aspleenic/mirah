require 'fileutils'
require 'rbconfig'
require 'mirah/transform'
require 'mirah/ast'
require 'mirah/typer'
require 'mirah/compiler'
require 'mirah/env'
begin
  require 'bitescript'
rescue LoadError
  $: << File.dirname(__FILE__) + '/../../bitescript/lib'
  require 'bitescript'
end
require 'mirah/jvm/compiler'
require 'mirah/jvm/typer'
Dir[File.dirname(__FILE__) + "/mirah/plugin/*"].each {|file| require "#{file}" if file =~ /\.rb$/}
require 'jruby'

module Duby
  def self.run(*args)
    DubyImpl.new.run(*args)
  end

  def self.compile(*args)
    DubyImpl.new.compile(*args)
  end

  def self.parse(*args)
    DubyImpl.new.parse(*args)
  end

  def self.plugins
    @plugins ||= []
  end

  def self.reset
    plugins.each {|x| x.reset if x.respond_to?(:reset)}
  end

  def self.print_error(message, position)
    puts "#{position.file}:#{position.start_line}: #{message}"
    file_offset = 0
    startline = position.start_line - 1
    endline = position.end_line - 1
    start_col = position.start_col - 1
    end_col = position.end_col - 1
    # don't try to search dash_e
    # TODO: show dash_e source the same way
    if File.exist? position.file
      File.open(position.file).each_with_index do |line, lineno|
        if lineno >= startline && lineno <= endline
          puts line.chomp
          if lineno == startline
            print ' ' * start_col
          else
            start_col = 0
          end
          if lineno < endline
            puts '^' * (line.size - start_col)
          else
            puts '^' * [end_col - start_col, 1].max
          end
        end
      end
    end
  end

  class CompilationState
    attr_accessor :verbose, :destination
  end
end

# This is a custom classloader impl to allow loading classes with
# interdependencies by having findClass retrieve classes as needed from the
# collection of all classes generated by the target script.
class DubyClassLoader < java::security::SecureClassLoader
  def initialize(parent, class_map)
    super(parent)
    @class_map = class_map
  end
  
  def findClass(name)
    if @class_map[name]
      bytes = @class_map[name].to_java_bytes
      defineClass(name, bytes, 0, bytes.length)
    else
      raise java.lang.ClassNotFoundException.new(name)
    end
  end

  def loadClass(name, resolve)
    cls = findLoadedClass(name)
    if cls == nil
      if @class_map[name]
        cls = findClass(name)
      else
        cls = super(name, false)
      end
    end

    resolveClass(cls) if resolve

    cls
  end
end

class DubyImpl
  def run(*args)
    ast = parse(*args)
    main = nil
    class_map = {}

    # generate all bytes for all classes
    compile_ast(ast) do |outfile, builder|
      bytes = builder.generate
      name = builder.class_name.gsub(/\//, '.')
      class_map[name] = bytes
    end

    # load all classes
    dcl = DubyClassLoader.new(java.lang.ClassLoader.system_class_loader, class_map)
    class_map.each do |name,|
      cls = dcl.load_class(name)
      # TODO: using first main; find correct one
      main ||= cls.get_method("main", java::lang::String[].java_class) #rescue nil
    end

    # run the main method we found
    if main
      begin
        main.invoke(nil, [args.to_java(:string)].to_java)
      rescue java.lang.Exception => e
        e = e.cause if e.cause
        raise e
      end
    else
      puts "No main found"
    end
  end

  def compile(*args)
    process_flags!(args)

    expand_files(args).each do |duby_file|
      if duby_file == '-e'
        @filename = '-e'
        next
      elsif @filename == '-e'
        ast = parse('-e', duby_file)
      else
        ast = parse(duby_file)
      end
      exit 1 if @error

      compile_ast(ast) do |filename, builder|
        filename = "#{@state.destination}#{filename}"
        FileUtils.mkdir_p(File.dirname(filename))
        bytes = builder.generate
        File.open(filename, 'w') {|f| f.write(bytes)}
      end
      @filename = nil
    end
  end

  def parse(*args)
    process_flags!(args)
    @filename = args.shift

    if @filename
      if @filename == '-e'
        @filename = 'DashE'
        src = args[0]
      else
        src = File.read(@filename)
      end
    else
      print_help
      exit(1)
    end
    Duby::AST.type_factory = Duby::JVM::Types::TypeFactory.new
    begin
      ast = Duby::AST.parse_ruby(src, @filename)
    # rescue org.jrubyparser.lexer.SyntaxException => ex
    #   Duby.print_error(ex.message, ex.position)
    #   raise ex if @state.verbose
    end
    @transformer = Duby::Transform::Transformer.new(@state)
    Java::MirahImpl::Builtin.initialize_builtins(@transformer)
    @transformer.filename = @filename
    ast = @transformer.transform(ast, nil)
    @transformer.errors.each do |ex|
      Duby.print_error(ex.message, ex.position)
      raise ex.cause || ex if @state.verbose
    end
    @error = @transformer.errors.size > 0

    ast
  end

  def compile_ast(ast, &block)
    typer = Duby::Typer::JVM.new(@transformer)
    typer.infer(ast)
    begin
      typer.resolve(false)
    ensure
      puts ast.inspect if @state.verbose

      failed = !typer.errors.empty?
      if failed
        puts "Inference Error:"
        typer.errors.each do |ex|
          if ex.node
            Duby.print_error(ex.message, ex.node.position)
          else
            puts ex.message
          end
          puts ex.backtrace if @state.verbose
        end
        exit 1
      end
    end

    begin
      compiler = @compiler_class.new
      ast.compile(compiler, false)
      compiler.generate(&block)
    rescue Exception => ex
      if ex.respond_to? :node
        Duby.print_error(ex.message, ex.node.position)
        puts ex.backtrace if @state.verbose
        exit 1
      else
        raise ex
      end
    end

  end

  def process_flags!(args)
    @state ||= Duby::CompilationState.new
    while args.length > 0 && args[0] =~ /^-/
      case args[0]
      when '--verbose', '-V'
        Duby::Typer.verbose = true
        Duby::AST.verbose = true
        Duby::Compiler::JVM.verbose = true
        @state.verbose = true
        args.shift
      when '--java', '-j'
        require 'mirah/jvm/source_compiler'
        @compiler_class = Duby::Compiler::JavaSource
        args.shift
      when '--dest', '-d'
        args.shift
        @state.destination = File.join(File.expand_path(args.shift), '')
      when '--cd'
        args.shift
        Dir.chdir(args.shift)
      when '--plugin', '-p'
        args.shift
        plugin = args.shift
        require "mirah/plugin/#{plugin}"
      when '-I'
        args.shift
        $: << args.shift
      when '--classpath', '-c'
        args.shift
        Duby::Env.decode_paths(args.shift, $CLASSPATH)
      when '--help', '-h'
        print_help
        exit(0)
      when '-e'
        break
      else
        puts "unrecognized flag: " + args[0]
        print_help
        exit(1)
      end
    end
    @state.destination ||= File.join(File.expand_path('.'), '')
    @compiler_class ||= Duby::Compiler::JVM
  end

  def print_help
    $stdout.print "#{$0} [flags] <files or \"-e SCRIPT\">
  -V, --verbose\t\tVerbose logging
  -j, --java\t\tOutput .java source (jrubyc only)
  -d, --dir DIR\t\tUse DIR as the base dir for compilation, packages
  -p, --plugin PLUGIN\tLoad and use plugin during compilation
  -c, --classpath PATH\tAdd PATH to the Java classpath for compilation
  -h, --help\t\tPrint this help message
  -e\t\t\tCompile or run the script following -e (naming it \"DashE\")"
  end

  def expand_files(files)
    expanded = []
    files.each do |filename|
      if File.directory?(filename)
        Dir[File.join(filename, '*')].each do |child|
          if File.directory?(child)
            files << child
          elsif child =~ /\.(duby|mirah)$/
            expanded << child
          end
        end
      else
        expanded << filename
      end
    end
    expanded
  end
end

Mirah = Duby

if __FILE__ == $0
  Duby.run(ARGV[0], *ARGV[1..-1])
end
