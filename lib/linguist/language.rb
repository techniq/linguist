require 'escape_utils'
require 'pygments'
require 'yaml'
begin
  require 'yajl'
rescue LoadError
end

require 'linguist/classifier'
require 'linguist/heuristics'
require 'linguist/samples'
require 'linguist/file_blob'
require 'linguist/blob_helper'

module Linguist
  # Language names that are recognizable by GitHub. Defined languages
  # can be highlighted, searched and listed under the Top Languages page.
  #
  # Languages are defined in `lib/linguist/languages.yml`.
  class Language
    @languages       = []
    @index           = {}
    @name_index      = {}
    @alias_index     = {}

    @extension_index          = Hash.new { |h,k| h[k] = [] }
    @interpreter_index        = Hash.new { |h,k| h[k] = [] }
    @filename_index           = Hash.new { |h,k| h[k] = [] }

    # Valid Languages types
    TYPES = [:data, :markup, :programming, :prose]

    # Names of non-programming languages that we will still detect
    #
    # Returns an array
    def self.detectable_markup
      ["CSS", "Less", "Sass", "SCSS", "Stylus", "TeX"]
    end

    # Detect languages by a specific type
    #
    # type - A symbol that exists within TYPES
    #
    # Returns an array
    def self.by_type(type)
      all.select { |h| h.type == type }
    end

    # Internal: Create a new Language object
    #
    # attributes - A hash of attributes
    #
    # Returns a Language object
    def self.create(attributes = {})
      language = new(attributes)

      @languages << language

      # All Language names should be unique. Raise if there is a duplicate.
      if @name_index.key?(language.name)
        raise ArgumentError, "Duplicate language name: #{language.name}"
      end

      # Language name index
      @index[language.name] = @name_index[language.name] = language

      language.aliases.each do |name|
        # All Language aliases should be unique. Raise if there is a duplicate.
        if @alias_index.key?(name)
          raise ArgumentError, "Duplicate alias: #{name}"
        end

        @index[name] = @alias_index[name] = language
      end

      language.extensions.each do |extension|
        if extension !~ /^\./
          raise ArgumentError, "Extension is missing a '.': #{extension.inspect}"
        end

        @extension_index[extension] << language
      end

      language.interpreters.each do |interpreter|
        @interpreter_index[interpreter] << language
      end

      language.filenames.each do |filename|
        @filename_index[filename] << language
      end

      language
    end

    # Public: Detects the Language of the blob.
    #
    # blob - an object that includes the Linguist `BlobHelper` interface;
    #       see Linguist::LazyBlob and Linguist::FileBlob for examples
    #
    # Returns Language or nil.
    def self.detect(blob)
      name = blob.name.to_s

      # Check if the blob is possibly binary and bail early; this is a cheap
      # test that uses the extension name to guess a binary binary mime type.
      #
      # We'll perform a more comprehensive test later which actually involves
      # looking for binary characters in the blob
      return nil if blob.likely_binary? || blob.binary?

      # A bit of an elegant hack. If the file is executable but extensionless,
      # append a "magic" extension so it can be classified with other
      # languages that have shebang scripts.
      extension = FileBlob.new(name).extension
      if extension.empty? && blob.mode && (blob.mode.to_i(8) & 05) == 05
        name += ".script!"
      end

      # First try to find languages that match based on filename.
      possible_languages = find_by_filename(name)

      # If there is more than one possible language with that extension (or no
      # extension at all, in the case of extensionless scripts), we need to continue
      # our detection work
      if possible_languages.length > 1
        data = blob.data
        possible_language_names = possible_languages.map(&:name)

        # Don't bother with binary contents or an empty file
        if data.nil? || data == ""
          nil
        # Check if there's a shebang line and use that as authoritative
        elsif (result = find_by_shebang(data)) && !result.empty?
          result.first
        # No shebang. Still more work to do. Try to find it with our heuristics.
        elsif (determined = Heuristics.find_by_heuristics(data, possible_language_names)) && !determined.empty?
          determined.first
        # Lastly, fall back to the probabilistic classifier.
        elsif classified = Classifier.classify(Samples.cache, data, possible_language_names).first
          # Return the actual Language object based of the string language name (i.e., first element of `#classify`)
          Language[classified[0]]
        end
      else
        # Simplest and most common case, we can just return the one match based on extension
        possible_languages.first
      end
    end

    # Public: Get all Languages
    #
    # Returns an Array of Languages
    def self.all
      @languages
    end

    # Public: Look up Language by its proper name.
    #
    # name - The String name of the Language
    #
    # Examples
    #
    #   Language.find_by_name('Ruby')
    #   # => #<Language name="Ruby">
    #
    # Returns the Language or nil if none was found.
    def self.find_by_name(name)
      @name_index[name]
    end

    # Public: Look up Language by one of its aliases.
    #
    # name - A String alias of the Language
    #
    # Examples
    #
    #   Language.find_by_alias('cpp')
    #   # => #<Language name="C++">
    #
    # Returns the Lexer or nil if none was found.
    def self.find_by_alias(name)
      @alias_index[name]
    end

    # Public: Look up Languages by filename.
    #
    # filename - The path String.
    #
    # Examples
    #
    #   Language.find_by_filename('foo.rb')
    #   # => [#<Language name="Ruby">]
    #
    # Returns all matching Languages or [] if none were found.
    def self.find_by_filename(filename)
      basename = File.basename(filename)
      extname = FileBlob.new(filename).extension
      langs = @filename_index[basename] +
              @extension_index[extname]
      langs.compact.uniq
    end

    # Public: Look up Languages by shebang line.
    #
    # data - Array of tokens or String data to analyze.
    #
    # Examples
    #
    #   Language.find_by_shebang("#!/bin/bash\ndate;")
    #   # => [#<Language name="Bash">]
    #
    # Returns the matching Language
    def self.find_by_shebang(data)
      @interpreter_index[Linguist.interpreter_from_shebang(data)]
    end

    # Public: Look up Language by its name or lexer.
    #
    # name - The String name of the Language
    #
    # Examples
    #
    #   Language['Ruby']
    #   # => #<Language name="Ruby">
    #
    #   Language['ruby']
    #   # => #<Language name="Ruby">
    #
    # Returns the Language or nil if none was found.
    def self.[](name)
      @index[name]
    end

    # Public: A List of popular languages
    #
    # Popular languages are sorted to the top of language chooser
    # dropdowns.
    #
    # This list is configured in "popular.yml".
    #
    # Returns an Array of Lexers.
    def self.popular
      @popular ||= all.select(&:popular?).sort_by { |lang| lang.name.downcase }
    end

    # Public: A List of non-popular languages
    #
    # Unpopular languages appear below popular ones in language
    # chooser dropdowns.
    #
    # This list is created from all the languages not listed in "popular.yml".
    #
    # Returns an Array of Lexers.
    def self.unpopular
      @unpopular ||= all.select(&:unpopular?).sort_by { |lang| lang.name.downcase }
    end

    # Public: A List of languages with assigned colors.
    #
    # Returns an Array of Languages.
    def self.colors
      @colors ||= all.select(&:color).sort_by { |lang| lang.name.downcase }
    end

    # Public: A List of languages compatible with Ace.
    #
    # Returns an Array of Languages.
    def self.ace_modes
      @ace_modes ||= all.select(&:ace_mode).sort_by { |lang| lang.name.downcase }
    end

    # Internal: Initialize a new Language
    #
    # attributes - A hash of attributes
    def initialize(attributes = {})
      # @name is required
      @name = attributes[:name] || raise(ArgumentError, "missing name")

      # Set type
      @type = attributes[:type] ? attributes[:type].to_sym : nil
      if @type && !TYPES.include?(@type)
        raise ArgumentError, "invalid type: #{@type}"
      end

      @color = attributes[:color]

      # Set aliases
      @aliases = [default_alias_name] + (attributes[:aliases] || [])

      # Lookup Lexer object
      @lexer = Pygments::Lexer.find_by_name(attributes[:lexer] || name) ||
        raise(ArgumentError, "#{@name} is missing lexer")

      @tm_scope = attributes[:tm_scope] || begin
        context = case @type
                  when :data, :markup, :prose
                    'text'
                  when :programming, nil
                    'source'
                  end
        "#{context}.#{@name.downcase}"
      end

      @ace_mode = attributes[:ace_mode]
      @wrap = attributes[:wrap] || false

      # Set legacy search term
      @search_term = attributes[:search_term] || default_alias_name

      # Set extensions or default to [].
      @extensions = attributes[:extensions] || []
      @interpreters = attributes[:interpreters]   || []
      @filenames  = attributes[:filenames]  || []

      # Set popular, and searchable flags
      @popular    = attributes.key?(:popular)    ? attributes[:popular]    : false
      @searchable = attributes.key?(:searchable) ? attributes[:searchable] : true

      # If group name is set, save the name so we can lazy load it later
      if attributes[:group_name]
        @group = nil
        @group_name = attributes[:group_name]

      # Otherwise we can set it to self now
      else
        @group = self
      end
    end

    # Public: Get proper name
    #
    # Examples
    #
    #   # => "Ruby"
    #   # => "Python"
    #   # => "Perl"
    #
    # Returns the name String
    attr_reader :name

    # Public: Get type.
    #
    # Returns a type Symbol or nil.
    attr_reader :type

    # Public: Get color.
    #
    # Returns a hex color String.
    attr_reader :color

    # Public: Get aliases
    #
    # Examples
    #
    #   Language['C++'].aliases
    #   # => ["cpp"]
    #
    # Returns an Array of String names
    attr_reader :aliases

    # Deprecated: Get code search term
    #
    # Examples
    #
    #   # => "ruby"
    #   # => "python"
    #   # => "perl"
    #
    # Returns the name String
    attr_reader :search_term

    # Public: Get Lexer
    #
    # Returns the Lexer
    attr_reader :lexer

    # Public: Get the name of a TextMate-compatible scope
    #
    # Returns the scope
    attr_reader :tm_scope

    # Public: Get Ace mode
    #
    # Examples
    #
    #  # => "text"
    #  # => "javascript"
    #  # => "c_cpp"
    #
    # Returns a String name or nil
    attr_reader :ace_mode

    # Public: Should language lines be wrapped
    #
    # Returns true or false
    attr_reader :wrap

    # Public: Get extensions
    #
    # Examples
    #
    #   # => ['.rb', '.rake', ...]
    #
    # Returns the extensions Array
    attr_reader :extensions

    # Public: Get interpreters
    #
    # Examples
    #
    #   # => ['awk', 'gawk', 'mawk' ...]
    #
    # Returns the interpreters Array
    attr_reader :interpreters

    # Public: Get filenames
    #
    # Examples
    #
    #   # => ['Rakefile', ...]
    #
    # Returns the extensions Array
    attr_reader :filenames

    # Public: Return all possible extensions for language
    def all_extensions
      (extensions + [primary_extension]).uniq
    end

    # Deprecated: Get primary extension
    #
    # Defaults to the first extension but can be overridden
    # in the languages.yml.
    #
    # The primary extension can not be nil. Tests should verify this.
    #
    # This method is only used by app/helpers/gists_helper.rb for creating
    # the language dropdown. It really should be using `name` instead.
    # Would like to drop primary extension.
    #
    # Returns the extension String.
    def primary_extension
      extensions.first
    end

    # Public: Get URL escaped name.
    #
    # Examples
    #
    #   "C%23"
    #   "C%2B%2B"
    #   "Common%20Lisp"
    #
    # Returns the escaped String.
    def escaped_name
      EscapeUtils.escape_url(name).gsub('+', '%20')
    end

    # Internal: Get default alias name
    #
    # Returns the alias name String
    def default_alias_name
      name.downcase.gsub(/\s/, '-')
    end

    # Public: Get Language group
    #
    # Returns a Language
    def group
      @group ||= Language.find_by_name(@group_name)
    end

    # Public: Is it popular?
    #
    # Returns true or false
    def popular?
      @popular
    end

    # Public: Is it not popular?
    #
    # Returns true or false
    def unpopular?
      !popular?
    end

    # Public: Is it searchable?
    #
    # Unsearchable languages won't by indexed by solr and won't show
    # up in the code search dropdown.
    #
    # Returns true or false
    def searchable?
      @searchable
    end

    # Public: Highlight syntax of text
    #
    # text    - String of code to be highlighted
    # options - A Hash of options (defaults to {})
    #
    # Returns html String
    def colorize(text, options = {})
      lexer.highlight(text, options)
    end

    # Public: Return name as String representation
    def to_s
      name
    end

    def ==(other)
      eql?(other)
    end

    def eql?(other)
      equal?(other)
    end

    def hash
      name.hash
    end

    def inspect
      "#<#{self.class} name=#{name}>"
    end
  end

  extensions = Samples.cache['extnames']
  interpreters = Samples.cache['interpreters']
  filenames = Samples.cache['filenames']
  popular = YAML.load_file(File.expand_path("../popular.yml", __FILE__))

  languages_yml = File.expand_path("../languages.yml", __FILE__)
  languages_json = File.expand_path("../languages.json", __FILE__)

  if File.exist?(languages_json) && defined?(Yajl)
    languages = Yajl.load(File.read(languages_json))
  else
    languages = YAML.load_file(languages_yml)
  end

  languages.each do |name, options|
    options['extensions'] ||= []
    options['interpreters'] ||= []
    options['filenames'] ||= []

    if extnames = extensions[name]
      extnames.each do |extname|
        if !options['extensions'].include?(extname)
          warn "#{name} has a sample with extension (#{extname}) that isn't explicitly defined in languages.yml" unless extname == '.script!'
          options['extensions'] << extname
        end
      end
    end

    if interpreters == nil
      interpreters = {}
    end

    if interpreter_names = interpreters[name]
      interpreter_names.each do |interpreter|
        if !options['interpreters'].include?(interpreter)
          options['interpreters'] << interpreter
        end
      end
    end

    if fns = filenames[name]
      fns.each do |filename|
        if !options['filenames'].include?(filename)
          options['filenames'] << filename
        end
      end
    end

    Language.create(
      :name              => name,
      :color             => options['color'],
      :type              => options['type'],
      :aliases           => options['aliases'],
      :lexer             => options['lexer'],
      :tm_scope          => options['tm_scope'],
      :ace_mode          => options['ace_mode'],
      :wrap              => options['wrap'],
      :group_name        => options['group'],
      :searchable        => options.key?('searchable') ? options['searchable'] : true,
      :search_term       => options['search_term'],
      :extensions        => [options['extensions'].first] + options['extensions'][1..-1].sort,
      :interpreters      => options['interpreters'].sort,
      :filenames         => options['filenames'],
      :popular           => popular.include?(name)
    )
  end
end
