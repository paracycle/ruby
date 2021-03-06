# frozen_string_literal: true

require_relative "command_execution"
require_relative "the_bundle"

module Spec
  module Helpers
    def reset!
      Dir.glob("#{tmp}/{gems/*,*}", File::FNM_DOTMATCH).each do |dir|
        next if %w[base remote1 gems rubygems . ..].include?(File.basename(dir))
        FileUtils.rm_rf(dir)
      end
      FileUtils.mkdir_p(home)
      FileUtils.mkdir_p(tmpdir)
      Bundler.reset!
    end

    def self.bang(method)
      define_method("#{method}!") do |*args, &blk|
        send(method, *args, &blk).tap do
          unless last_command.success?
            raise "Invoking #{method}!(#{args.map(&:inspect).join(", ")}) failed:\n#{last_command.stdboth}"
          end
        end
      end
    end

    def the_bundle(*args)
      TheBundle.new(*args)
    end

    def last_command
      @command_executions.last || raise("There is no last command")
    end

    def out
      last_command.stdout
    end

    def err
      last_command.stderr
    end

    MAJOR_DEPRECATION = /^\[DEPRECATED\]\s*/.freeze

    def err_without_deprecations
      err.gsub(/#{MAJOR_DEPRECATION}.+[\n]?/, "")
    end

    def deprecations
      err.split("\n").select {|l| l =~ MAJOR_DEPRECATION }.join("\n").split(MAJOR_DEPRECATION)
    end

    def exitstatus
      last_command.exitstatus
    end

    def run(cmd, *args)
      opts = args.last.is_a?(Hash) ? args.pop : {}
      groups = args.map(&:inspect).join(", ")
      setup = "require '#{lib_dir}/bundler' ; Bundler.ui.silence { Bundler.setup(#{groups}) }"
      ruby([setup, cmd].join(" ; "), opts)
    end
    bang :run

    def load_error_run(ruby, name, *args)
      cmd = <<-RUBY
        begin
          #{ruby}
        rescue LoadError => e
          warn "ZOMG LOAD ERROR" if e.message.include?("-- #{name}")
        end
      RUBY
      opts = args.last.is_a?(Hash) ? args.pop : {}
      args += [opts]
      run(cmd, *args)
    end

    def bundle(cmd, options = {}, &block)
      with_sudo = options.delete(:sudo)
      sudo = with_sudo == :preserve_env ? "sudo -E --preserve-env=RUBYOPT" : "sudo" if with_sudo

      bundle_bin = options.delete("bundle_bin") || bindir.join("bundle")

      if system_bundler = options.delete(:system_bundler)
        bundle_bin = system_gem_path.join("bin/bundler")
      end

      env = options.delete(:env) || {}
      env["PATH"].gsub!("#{Path.root}/exe", "") if env["PATH"] && system_bundler

      requires = options.delete(:requires) || []

      artifice = options.delete(:artifice) do
        if RSpec.current_example.metadata[:realworld]
          "vcr"
        else
          "fail"
        end
      end
      if artifice
        requires << "#{Path.spec_dir}/support/artifice/#{artifice}.rb"
      end

      load_path = []
      load_path << lib_dir unless system_bundler
      load_path << spec_dir

      dir = options.delete(:dir) || bundled_app

      args = options.map do |k, v|
        case v
        when nil
          next
        when true
          " --#{k}"
        when false
          " --no-#{k}"
        else
          " --#{k} #{v}"
        end
      end.join

      ruby_cmd = build_ruby_cmd({ :sudo => sudo, :load_path => load_path, :requires => requires })
      cmd = "#{ruby_cmd} #{bundle_bin} #{cmd}#{args}"
      sys_exec(cmd, { :env => env, :dir => dir }, &block)
    end
    bang :bundle

    def forgotten_command_line_options(options)
      remembered = Bundler::VERSION.split(".", 2).first == "2"
      options = options.map do |k, v|
        v = '""' if v && v.to_s.empty?
        [k, v]
      end
      return Hash[options] if remembered
      options.each do |k, v|
        if v.nil?
          bundle! "config unset #{k}"
        else
          bundle! "config set --local #{k} #{v}"
        end
      end
      {}
    end

    def bundler(cmd, options = {})
      options["bundle_bin"] = bindir.join("bundler")
      bundle(cmd, options)
    end

    def ruby(ruby, options = {})
      ruby_cmd = build_ruby_cmd({ :load_path => options[:no_lib] ? [] : [lib_dir] })
      escaped_ruby = RUBY_PLATFORM == "java" ? ruby.shellescape.dump : ruby.shellescape
      sys_exec(%(#{ruby_cmd} -w -e #{escaped_ruby}), options)
    end
    bang :ruby

    def load_error_ruby(ruby, name, opts = {})
      ruby(<<-R)
        begin
          #{ruby}
        rescue LoadError => e
          warn "ZOMG LOAD ERROR" if e.message.include?("-- #{name}")
        end
      R
    end

    def build_ruby_cmd(options = {})
      sudo = options.delete(:sudo)

      libs = options.delete(:load_path) || []
      lib_option = "-I#{libs.join(File::PATH_SEPARATOR)}"

      requires = options.delete(:requires) || []
      requires << "#{Path.spec_dir}/support/hax.rb"
      require_option = requires.map {|r| "-r#{r}" }

      [sudo, Gem.ruby, *lib_option, *require_option].compact.join(" ")
    end

    def gembin(cmd, options = {})
      old = ENV["RUBYOPT"]
      ENV["RUBYOPT"] = "#{ENV["RUBYOPT"]} -I#{lib_dir}"
      cmd = bundled_app("bin/#{cmd}") unless cmd.to_s.include?("/")
      sys_exec(cmd.to_s, options)
    ensure
      ENV["RUBYOPT"] = old
    end

    def gem_command(command, options = {})
      sys_exec("#{Path.gem_bin} #{command}", options)
    end
    bang :gem_command

    def rake
      "#{Gem.ruby} -S #{ENV["GEM_PATH"]}/bin/rake"
    end

    def git(cmd, path)
      sys_exec("git #{cmd}", :dir => path)
    end

    def sys_exec(cmd, options = {})
      env = options[:env] || {}
      env["RUBYOPT"] = opt_add("-r#{spec_dir}/support/switch_rubygems.rb", env["RUBYOPT"] || ENV["RUBYOPT"])
      dir = options[:dir] || bundled_app
      command_execution = CommandExecution.new(cmd.to_s, dir)

      require "open3"
      require "shellwords"
      Open3.popen3(env, *cmd.shellsplit, :chdir => dir) do |stdin, stdout, stderr, wait_thr|
        yield stdin, stdout, wait_thr if block_given?
        stdin.close

        stdout_read_thread = Thread.new { stdout.read }
        stderr_read_thread = Thread.new { stderr.read }
        command_execution.stdout = stdout_read_thread.value.strip
        command_execution.stderr = stderr_read_thread.value.strip
        command_execution.exitstatus = wait_thr && wait_thr.value.exitstatus
      end

      (@command_executions ||= []) << command_execution

      command_execution.stdout
    end
    bang :sys_exec

    def config(config = nil, path = bundled_app(".bundle/config"))
      return YAML.load_file(path) unless config
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "w") do |f|
        f.puts config.to_yaml
      end
      config
    end

    def global_config(config = nil)
      config(config, home(".bundle/config"))
    end

    def create_file(*args)
      path = bundled_app(args.shift)
      path = args.shift if args.first.is_a?(Pathname)
      str  = args.shift || ""
      path.dirname.mkpath
      File.open(path.to_s, "w") do |f|
        f.puts strip_whitespace(str)
      end
    end

    def gemfile(*args)
      contents = args.shift

      if contents.nil?
        File.open(bundled_app_gemfile, "r", &:read)
      else
        create_file("Gemfile", contents, *args)
      end
    end

    def lockfile(*args)
      contents = args.shift

      if contents.nil?
        File.open(bundled_app_lock, "r", &:read)
      else
        create_file("Gemfile.lock", contents, *args)
      end
    end

    def strip_whitespace(str)
      # Trim the leading spaces
      spaces = str[/\A\s+/, 0] || ""
      str.gsub(/^#{spaces}/, "")
    end

    def install_gemfile(*args)
      gemfile(*args)
      opts = args.last.is_a?(Hash) ? args.last : {}
      opts[:retry] ||= 0
      bundle :install, opts
    end
    bang :install_gemfile

    def lock_gemfile(*args)
      gemfile(*args)
      opts = args.last.is_a?(Hash) ? args.last : {}
      opts[:retry] ||= 0
      bundle :lock, opts
    end

    def install_gems(*gems)
      options = gems.last.is_a?(Hash) ? gems.pop : {}
      gem_repo = options.fetch(:gem_repo) { gem_repo1 }
      gems.each do |g|
        gem_name = g.to_s
        if gem_name.start_with?("bundler")
          version = gem_name.match(/\Abundler-(?<version>.*)\z/)[:version] if gem_name != "bundler"
          with_built_bundler(version) {|gem_path| install_gem(gem_path) }
        elsif gem_name =~ %r{\A(?:[a-zA-Z]:)?/.*\.gem\z}
          install_gem(gem_name)
        else
          install_gem("#{gem_repo}/gems/#{gem_name}.gem")
        end
      end
    end

    def install_gem(path)
      raise "OMG `#{path}` does not exist!" unless File.exist?(path)

      gem_command! "install --no-document --ignore-dependencies '#{path}'"
    end

    def with_built_bundler(version = nil)
      version ||= Bundler::VERSION
      full_name = "bundler-#{version}"
      build_path = tmp + full_name
      bundler_path = build_path + "#{full_name}.gem"

      Dir.mkdir build_path

      begin
        shipped_files.each do |shipped_file|
          target_shipped_file = build_path + shipped_file
          target_shipped_dir = File.dirname(target_shipped_file)
          FileUtils.mkdir_p target_shipped_dir unless File.directory?(target_shipped_dir)
          FileUtils.cp shipped_file, target_shipped_file, :preserve => true
        end

        replace_version_file(version, dir: build_path) # rubocop:disable Style/HashSyntax

        gem_command! "build #{shipped_gemspec}", :dir => build_path

        yield(bundler_path)
      ensure
        build_path.rmtree
      end
    end

    def with_gem_path_as(path)
      backup = ENV.to_hash
      ENV["GEM_HOME"] = path.to_s
      ENV["GEM_PATH"] = path.to_s
      ENV["BUNDLER_ORIG_GEM_PATH"] = nil
      yield
    ensure
      ENV.replace(backup)
    end

    def with_path_as(path)
      backup = ENV.to_hash
      ENV["PATH"] = path.to_s
      ENV["BUNDLER_ORIG_PATH"] = nil
      yield
    ensure
      ENV.replace(backup)
    end

    def with_path_added(path)
      with_path_as(path.to_s + ":" + ENV["PATH"]) do
        yield
      end
    end

    def opt_add(option, options)
      [option.strip, options].compact.reject(&:empty?).join(" ")
    end

    def opt_remove(option, options)
      return unless options

      options.split(" ").reject {|opt| opt.strip == option.strip }.join(" ")
    end

    def break_git!
      FileUtils.mkdir_p(tmp("broken_path"))
      File.open(tmp("broken_path/git"), "w", 0o755) do |f|
        f.puts "#!/usr/bin/env ruby\nSTDERR.puts 'This is not the git you are looking for'\nexit 1"
      end

      ENV["PATH"] = "#{tmp("broken_path")}:#{ENV["PATH"]}"
    end

    def with_fake_man
      skip "fake_man is not a Windows friendly binstub" if Gem.win_platform?

      FileUtils.mkdir_p(tmp("fake_man"))
      File.open(tmp("fake_man/man"), "w", 0o755) do |f|
        f.puts "#!/usr/bin/env ruby\nputs ARGV.inspect\n"
      end
      with_path_added(tmp("fake_man")) { yield }
    end

    def system_gems(*gems)
      opts = gems.last.is_a?(Hash) ? gems.last : {}
      path = opts.fetch(:path, system_gem_path)
      gems = gems.flatten

      unless opts[:keep_path]
        FileUtils.rm_rf(path)
        FileUtils.mkdir_p(path)
      end

      Gem.clear_paths

      env_backup = ENV.to_hash
      ENV["GEM_HOME"] = path.to_s
      ENV["GEM_PATH"] = path.to_s
      ENV["BUNDLER_ORIG_GEM_PATH"] = nil

      install_gems(*gems)
      return unless block_given?
      begin
        yield
      ensure
        ENV.replace(env_backup)
      end
    end

    def realworld_system_gems(*gems)
      gems = gems.flatten

      FileUtils.rm_rf(system_gem_path)
      FileUtils.mkdir_p(system_gem_path)

      Gem.clear_paths

      gem_home = ENV["GEM_HOME"]
      gem_path = ENV["GEM_PATH"]
      path = ENV["PATH"]
      ENV["GEM_HOME"] = system_gem_path.to_s
      ENV["GEM_PATH"] = system_gem_path.to_s

      gems.each do |gem|
        gem_command! "install --no-document #{gem}"
      end
      return unless block_given?
      begin
        yield
      ensure
        ENV["GEM_HOME"] = gem_home
        ENV["GEM_PATH"] = gem_path
        ENV["PATH"] = path
      end
    end

    def cache_gems(*gems)
      gems = gems.flatten

      FileUtils.rm_rf("#{bundled_app}/vendor/cache")
      FileUtils.mkdir_p("#{bundled_app}/vendor/cache")

      gems.each do |g|
        path = "#{gem_repo1}/gems/#{g}.gem"
        raise "OMG `#{path}` does not exist!" unless File.exist?(path)
        FileUtils.cp(path, "#{bundled_app}/vendor/cache")
      end
    end

    def simulate_new_machine
      system_gems []
      FileUtils.rm_rf system_gem_path
      FileUtils.rm_rf bundled_app(".bundle")
    end

    def simulate_platform(platform)
      old = ENV["BUNDLER_SPEC_PLATFORM"]
      ENV["BUNDLER_SPEC_PLATFORM"] = platform.to_s
      yield if block_given?
    ensure
      ENV["BUNDLER_SPEC_PLATFORM"] = old if block_given?
    end

    def simulate_ruby_version(version)
      return if version == RUBY_VERSION
      old = ENV["BUNDLER_SPEC_RUBY_VERSION"]
      ENV["BUNDLER_SPEC_RUBY_VERSION"] = version
      yield if block_given?
    ensure
      ENV["BUNDLER_SPEC_RUBY_VERSION"] = old if block_given?
    end

    def simulate_windows(platform = mswin)
      old = ENV["BUNDLER_SPEC_WINDOWS"]
      ENV["BUNDLER_SPEC_WINDOWS"] = "true"
      simulate_platform platform do
        yield
      end
    ensure
      ENV["BUNDLER_SPEC_WINDOWS"] = old
    end

    def revision_for(path)
      sys_exec("git rev-parse HEAD", :dir => path).strip
    end

    def with_read_only(pattern)
      chmod = lambda do |dirmode, filemode|
        lambda do |f|
          mode = File.directory?(f) ? dirmode : filemode
          File.chmod(mode, f)
        end
      end

      Dir[pattern].each(&chmod[0o555, 0o444])
      yield
    ensure
      Dir[pattern].each(&chmod[0o755, 0o644])
    end

    # Simulate replacing TODOs with real values
    def prepare_gemspec(pathname)
      process_file(pathname) do |line|
        case line
        when /spec\.metadata\["(?:allowed_push_host|homepage_uri|source_code_uri|changelog_uri)"\]/, /spec\.homepage/
          line.gsub(/\=.*$/, "= 'http://example.org'")
        when /spec\.summary/
          line.gsub(/\=.*$/, "= %q{A short summary of my new gem.}")
        when /spec\.description/
          line.gsub(/\=.*$/, "= %q{A longer description of my new gem.}")
        else
          line
        end
      end
    end

    def process_file(pathname)
      changed_lines = pathname.readlines.map do |line|
        yield line
      end
      File.open(pathname, "w") {|file| file.puts(changed_lines.join) }
    end

    def with_env_vars(env_hash, &block)
      current_values = {}
      env_hash.each do |k, v|
        current_values[k] = ENV[k]
        ENV[k] = v
      end
      block.call if block_given?
      env_hash.each do |k, _|
        ENV[k] = current_values[k]
      end
    end

    def require_rack
      # need to hack, so we can require rack
      old_gem_home = ENV["GEM_HOME"]
      ENV["GEM_HOME"] = Spec::Path.base_system_gems.to_s
      require "rack"
      ENV["GEM_HOME"] = old_gem_home
    end

    def wait_for_server(host, port, seconds = 15)
      tries = 0
      sleep 0.5
      TCPSocket.new(host, port)
    rescue StandardError => e
      raise(e) if tries > (seconds * 2)
      tries += 1
      retry
    end

    def find_unused_port
      port = 21_453
      begin
        port += 1 while TCPSocket.new("127.0.0.1", port)
      rescue StandardError
        false
      end
      port
    end
  end
end
