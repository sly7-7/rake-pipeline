require "rake-pipeline/file_wrapper"
require "rake-pipeline/filter"
require "rake-pipeline/manifest_entry"
require "rake-pipeline/manifest"
require "rake-pipeline/dynamic_file_task"
require "rake-pipeline/filters"
require "rake-pipeline/dsl"
require "rake-pipeline/matcher"
require "rake-pipeline/reject_matcher"
require "rake-pipeline/sorted_pipeline"
require "rake-pipeline/error"
require "rake-pipeline/project"
require "rake-pipeline/cli"
require "rake-pipeline/graph"

if defined?(Rails::Railtie)
  require "rake-pipeline/railtie"
elsif defined?(Rails)
  require "rake-pipeline/rails_plugin"
end

require "thread"

# Use the Rake namespace
module Rake
  # Override Rake::Task to support recursively re-enabling
  # a task and its dependencies.
  class Task

    # @param [Rake::Application] app a Rake Application
    # @return [void]
    def recursively_reenable(app)
      reenable

      prerequisites.each do |dep|
        app[dep].recursively_reenable(app)
      end
    end
  end

  # Override Rake::FileTask to make it sortable
  class FileTask
    # implement Ruby protocol for sorting
    #
    # @return [Fixnum]
    def <=>(other)
      [name, prerequisites] <=> [other.name, other.prerequisites]
    end
  end

  # A Pipeline is responsible for taking a directory of input
  # files, applying a number of filters to the inputs, and
  # outputting them into an output directory.
  #
  # The normal way to build and configure a pipeline is by
  # using {.build}. Inside the block passed to {.build}, all
  # methods of {DSL} are available.
  #
  # @see DSL Rake::Pipeline::DSL for information on the methods
  #   available inside the block.
  #
  # @example
  #   !!!ruby
  #   Rake::Pipeline.build do
  #     # process all js, css and html files in app/assets
  #     input "app/assets", "**/*.{js,coffee,css,scss,html}"
  #
  #     # processed files should be outputted to public
  #     output "public"
  #
  #     # process all coffee files
  #     match "*.coffee" do
  #       # compile all CoffeeScript files. the output file
  #       # for the compilation should be the input name
  #       # with the .coffee extension replaced with .js
  #       filter(CoffeeCompiler) do |input|
  #         input.sub(/\.coffee$/, '.js')
  #       end
  #     end
  #
  #     # specify filters for js files. this includes the
  #     # output of the previous step, which converted
  #     # coffee files to js files
  #     match "*.js" do
  #       # first, wrap all JS files in a custom filter
  #       filter ClosureFilter
  #       # then, concatenate all JS files into a single file
  #       concat "application.js"
  #     end
  #
  #     # specify filters for css and scss files
  #     match "*.{css,scss}" do
  #       # compile CSS and SCSS files using the SCSS
  #       # compiler. if an input file has the extension
  #       # scss, replace it with css
  #       filter(ScssCompiler) do |input|
  #         input.sub(/\.scss$/, 'css')
  #       end
  #       # then, concatenate all CSS files into a single file
  #       concat "application.css"
  #     end
  #
  #     # the remaining files not specified by a matcher (the
  #     # HTML files) are simply copied over.
  #
  #     # you can also specify filters here that will apply to
  #     # all processed files (application.js and application.css)
  #     # up until this point, as well as the HTML files.
  #   end
  class Pipeline
    class Error < StandardError ; end
    class TmpInputError < Error
      def initialize(file)
        @file = file
      end

      def to_s
        "Temporary files cannot be input! #{@file} is inside a pipeline's tmp directory"
      end
    end

    # @return [Hash[String, String]] the directory paths for the input files
    #   and their matching globs.
    attr_accessor :inputs

    # @return [String] the directory path for the output files.
    attr_reader   :output_root

    # @return [String] the directory path for temporary files
    attr_accessor :tmpdir

    # @return [Array] an Array of Rake::Task objects. This
    #   property is populated by the #generate_rake_tasks
    #   method.
    attr_reader   :rake_tasks

    # @return [String] a list of files that will be outputted
    #   to the output directory when the pipeline is invoked
    attr_reader   :output_files

    # @return [Array] this pipeline's filters.
    attr_reader   :filters

    attr_writer :input_files

    # @return [Project] the Project that created this pipeline
    attr_accessor :project

    # @param [Hash] options
    # @option options [Hash] :inputs
    #   set the pipeline's {#inputs}.
    # @option options [String] :tmpdir
    #   set the pipeline's {#tmpdir}.
    # @option options [String] :output_root
    #   set the pipeline's {#output_root}.
    # @option options [Rake::Application] :rake_application
    #   set the pipeline's {#rake_application}.
    def initialize(options={})
      @filters         = []
      @invoke_mutex    = Mutex.new
      @clean_mutex     = Mutex.new
      @tmp_id          = 0
      @inputs          = options[:inputs] || {}
      @tmpdir          = options[:tmpdir] || File.expand_path("tmp")
      @project         = options[:project]

      if options[:output_root]
        self.output_root = options[:output_root]
      end

      if options[:rake_application]
        self.rake_application = options[:rake_application]
      end
    end

    # Build a new pipeline taking a block. The block will
    # be evaluated by the Rake::Pipeline::DSL class.
    #
    # @see Rake::Pipeline::Filter Rake::Pipeline::Filter
    #
    # @example
    #   Rake::Pipeline.build do
    #     input "app/assets"
    #     output "public"
    #
    #     concat "app.js"
    #   end
    #
    # @see DSL the Rake::Pipeline::DSL documentation.
    #   All instance methods of DSL are available inside
    #   the build block.
    #
    # @return [Rake::Pipeline] the newly configured pipeline
    def self.build(options={}, &block)
      pipeline = new(options)
      pipeline.build(options, &block)
    end

    # Evaluate a block using the Rake::Pipeline DSL against an
    # existing pipeline.
    #
    # @see Rake::Pipeline.build
    #
    # @return [Rake::Pipeline] this pipeline with any modifications
    #   made by the given block.
    def build(options={}, &block)
      DSL::PipelineDSL.evaluate(self, options, &block) if block
      self
    end

    # Copy the current pipeline's attributes over.
    #
    # @param [Class] target_class the class to create a new
    #   instance of. Defaults to the class of the current
    #   pipeline. Is overridden in {Matcher}
    # @param [Proc] block a block to pass to the {DSL DSL}
    # @return [Pipeline] the new pipeline
    # @api private
    def copy(target_class=self.class, &block)
      pipeline = target_class.new
      pipeline.inputs = inputs
      pipeline.tmpdir = tmpdir
      pipeline.rake_application = rake_application
      pipeline.project = project
      pipeline.build &block
      pipeline
    end

    # Set the output root of this pipeline and expand its path.
    #
    # @param [String] root this pipeline's output root
    def output_root=(root)
      @output_root = File.expand_path(root)
    end

    # Set the temporary directory for this pipeline and expand its path.
    #
    # @param [String] root this pipeline's temporary directory
    def tmpdir=(dir)
      @tmpdir = File.expand_path(dir)
    end

    # Add an input directory, optionally filtering which files within
    # the input directory are included.
    #
    # @param [String] root the input root directory; required
    # @param [String] pattern a pattern to match within +root+;
    #   optional; defaults to "**/*"
    def add_input(root, pattern = nil)
      pattern ||= "**/*"
      @inputs[root] = pattern
    end

    # If you specify #inputs, this method will
    # calculate the input files for the directory. If you supply
    # input_files directly, this method will simply return the
    # input_files you supplied.
    #
    # @return [Array<FileWrapper>] An Array of file wrappers
    #   that represent the inputs for the current pipeline.
    def input_files
      return @input_files if @input_files

      assert_input_provided

      result = []

      @inputs.each do |root, glob|
        expanded_root = File.expand_path(root)
        files = Dir[File.join(expanded_root, glob)].sort.select { |f| File.file?(f) }

        files.each do |file|
          relative_path = file.sub(%r{^#{Regexp.escape(expanded_root)}/}, '')
          result << FileWrapper.new(expanded_root, relative_path)
        end
      end

      result.sort
    end

    # for Pipelines, this is every file, but it may be overridden
    # by subclasses
    alias eligible_input_files input_files

    # @return [Rake::Application] The Rake::Application to install
    #   rake tasks onto. Defaults to Rake.application
    def rake_application
      @rake_application || Rake.application
    end

    # Set the rake_application on the pipeline and apply it to filters.
    #
    # @return [void]
    def rake_application=(rake_application)
      @rake_application = rake_application
      @filters.each { |filter| filter.rake_application = rake_application }
      @rake_tasks = nil
    end

    # Add one or more filters to the current pipeline.
    #
    # @param [Array<Filter>] filters a list of filters
    # @return [void]
    def add_filters(*filters)
      filters.each do |filter|
        filter.rake_application = rake_application
        filter.pipeline = self
      end
      @filters.concat(filters)
    end
    alias add_filter add_filters

    # Invoke the pipeline, processing the inputs into the output.
    #
    # @return [void]
    def invoke
      @invoke_mutex.synchronize do
        @tmp_id = 0

        self.rake_application = Rake::Application.new

        setup

        @rake_tasks.each { |task| task.invoke }
      end
    end

    # Set up the filters and generate rake tasks. In general, this method
    # is called by invoke.
    #
    # @return [void]
    # @api private
    def setup
      setup_filters
      generate_rake_tasks
    end

    # Set up the filters. This will loop through all of the filters for
    # the current pipeline and wire up their input_files and output_files.
    #
    # Because matchers implement the filter API, matchers will also be
    # set up as part of this process.
    #
    # @return [void]
    # @api private
    def setup_filters
      # First verify that everything can actually be an input
      # FIXME: define eligible_input_files to filter out tmpfile
      eligible_input_files.each do |file|
        raise TmpInputError, file.fullpath if file.in_directory? tmpdir
      end

      last = @filters.last

      @filters.inject(eligible_input_files) do |current_inputs, filter|
        filter.input_files = current_inputs

        # if filters are being reinvoked, they should keep their roots but
        # get updated with new files.
        filter.output_root ||= begin
          output = if filter == last
            output_root
          else
            generate_tmpdir
          end

          File.expand_path(output)
        end

        filter.setup_filters if filter.respond_to?(:setup_filters)

        filter.output_files
      end
    end

    # A list of the output files that invoking this pipeline will
    # generate.
    #
    # @return [Array<FileWrapper>]
    def output_files
      @filters.last.output_files unless @filters.empty?
    end

    # Add a final filter to the pipeline that will copy the
    # pipeline's generated files to the output.
    #
    # @return [void]
    # @api private
    def finalize
      add_filter(Rake::Pipeline::PipelineFinalizingFilter.new)
    end

    # A unique fingerprint. It's used to generate unique temporary
    # directory names. It must be unique to the pipeline. It must be
    # the same across processes.
    def fingerprint
      files = eligible_input_files + output_files

      Digest::MD5.hexdigest(files.to_s)[0..7]
    end

    # the Manifest used in this pipeline
    def manifest
      project.manifest
    end

  protected
    # Generate a new temporary directory name.
    #
    # @return [String] a unique temporary directory name
    def generate_tmpname
      "rake-pipeline-#{fingerprint}-tmp-#{@tmp_id += 1}"
    end

    # Generate a new temporary directory name under the main tmpdir.
    #
    # @return [void]
    def generate_tmpdir
      File.join(tmpdir, self.generate_tmpname)
    end

    # Generate all of the rake tasks for this pipeline.
    #
    # @return [void]
    def generate_rake_tasks
      @rake_tasks = filters.collect { |f| f.generate_rake_tasks }.flatten
    end

    # Assert that an input root and glob were both provided.
    #
    # @raise Rake::Pipeline::Error if input root or glob were missing.
    # @return [void]
    def assert_input_provided
      if inputs.empty?
        raise Rake::Pipeline::Error, "You cannot get input files without " \
                                     "first providing input files and an input root"
      end
    end

  end
end
