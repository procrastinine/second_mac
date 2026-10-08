#!/usr/bin/ruby
require 'json'
require 'pathname'
require 'open3'
require 'yaml'
require 'set'

# A small command adapter: local settings and installed-file checks. Resolution and installation
# remain the responsibility of the installed package manager.
module ProjectTool
  def self.native(tool, paths = ENV.fetch('PATH', '').split(File::PATH_SEPARATOR))
    own = File.realpath(__FILE__)
    paths.map { |dir| File.join(dir, tool) }.find do |file|
      File.file?(file) && File.executable?(file) && File.realpath(file) != own
    end || raise("Install #{tool} before using this project.")
  end

  def self.directory(args, tool)
    directory = Dir.pwd
    index = 0
    flags = tool == 'uv' ? %w[--directory --project -C] : %w[--dir -C]
    while index < args.length
      value = args[index]
      break if value == '--' || %w[run exec x dlx].include?(value)
      if flags.include?(value)
        index += 1
        directory = File.expand_path(args.fetch(index), directory)
      elsif flags.any? { |flag| value.start_with?(flag + '=') }
        directory = File.expand_path(value.split('=', 2).last, directory)
      end
      index += 1
    end
    File.realpath(directory)
  end

  def self.project(rows, directory, tool)
    # An independently registered nested project takes precedence.
    row = rows.select { |item| directory == item.fetch('root') || directory.start_with?(item.fetch('root') + '/') }
      .max_by { |item| item.fetch('root').length }
    row if row && row.fetch('tools').include?(tool)
  end

  def self.direct_binary(file)
    # pnpm's own cmd-shim records the current target. Read it on every call,
    # so self-update can replace the target without reinstalling this adapter.
    8.times do
      file = File.realpath(file)
      source = File.binread(file, 16384)
      return file unless source.start_with?('#!')
      target = source[/^# cmd-shim-target=(.+)$/, 1]
      return file unless target
      file = File.expand_path(target, File.dirname(file))
    end
    raise 'Package-manager command has a cyclic shim target.'
  end

  # Read the command prefix, never options passed on to an application script.
  def self.command(args)
    index = 0
    while index < args.length
      value = args[index]
      return nil if value == '--'
      return value unless value.start_with?('-')
      index += 1 if %w[-C --dir --filter -F --filter-prod --workspace-concurrency --registry --store-dir --reporter --loglevel --config].include?(value)
      index += 1
    end
    nil
  end

  def self.runs_code?(args, directory)
    cmd = command(args)
    return true if %w[run run-script exec x].include?(cmd)
    # Built-in installation commands must remain available to repair the tree.
    return false if %w[install i add update up remove rm uninstall rebuild import fetch].include?(cmd)
    manifest = File.join(directory, 'package.json')
    File.file?(manifest) && JSON.parse(File.read(manifest)).fetch('scripts', {}).key?(cmd)
  end

  def self.check_packages(nodes, skipped, groups, seen = Set.new)
    Array(nodes).each do |node|
      if node['path'] && node['version']
        identity = "#{node['from']}@#{node['version']}"
        next if skipped.include?(identity) || !seen.add?([node['path'], node['version']])
        file = File.join(node['path'], 'package.json')
        raise "Missing installed dependency #{identity}. Run pnpm install --frozen-lockfile to repair the shared tree." unless File.file?(file)
        actual = JSON.parse(File.read(file))['version']
        if node['version'].match?(/\A\d+\.\d+\.\d+/) && actual != node['version']
          raise "Installed #{identity} has version #{actual.inspect}. Run pnpm install --frozen-lockfile to repair the shared tree."
        end
      end
      groups.each { |group| check_packages(node.fetch(group, {}).values, skipped, groups, seen) }
    end
  end

  def self.verify_installed(executable, settings, row, args, directory)
    metadata = File.join(row.fetch('root'), 'node_modules/.modules.yaml')
    return unless File.file?(metadata) # pnpm itself diagnoses an uninstalled tree.
    modules = YAML.safe_load(File.read(metadata))
    skipped = Set.new(modules.fetch('skipped', []).map { |key| key.split('(', 2).first })
    groups = modules.fetch('included').select { |_key, value| value }.keys
    selection = []
    args.each_with_index do |arg, index|
      break if arg == command(args) || arg == '--'
      selection << arg if %w[-r --recursive --workspace-root -w].include?(arg) || arg.start_with?('--filter=')
      selection.concat([arg, args.fetch(index + 1)]) if %w[--filter -F --filter-prod].include?(arg)
    end
    output, error, status = Open3.capture3(settings, executable, *selection, 'list', '--depth', 'Infinity', '--json', chdir:directory)
    raise "Cannot verify installed dependencies: #{error}" unless status.success?
    check_packages(JSON.parse(output), skipped, groups)
  end

  def self.run(tool, args)
    executable = native(tool)
    cmd = command(args)
    prefix = args.take_while { |arg| arg != cmd }
    global = tool == 'pnpm' && (%w[self-update setup].include?(cmd) ||
      prefix.any? { |arg| %w[-g --global].include?(arg) } ||
      (%w[install i add update up remove rm uninstall list ls].include?(cmd) && args.any? { |arg| %w[-g --global].include?(arg) }))
    config = File.join(Dir.home, '.config/project-tools/projects.json')
    rows = File.file?(config) ? JSON.parse(File.read(config)).fetch('projects') : []
    row = !global && project(rows, directory(args, tool), tool)
    settings = {}
    if row && tool == 'pnpm'
      settings.merge!('PNPM_CONFIG_STORE_DIR'=>row.fetch('store'),
        'PNPM_CONFIG_ENABLE_GLOBAL_VIRTUAL_STORE'=>'false',
        'PNPM_CONFIG_VERIFY_DEPS_BEFORE_RUN'=>'error')
    elsif row && tool == 'uv'
      settings['UV_PROJECT_ENVIRONMENT'] = row.fetch('environment')
      settings['UV_CACHE_DIR'] = row.fetch('uv_cache')
      settings['UV_PYTHON_INSTALL_DIR'] = row.fetch('python_dir')
    end
    if row && row['fsync_library']
      executable = direct_binary(executable)
      if File.binread(executable, 2) == '#!'
        raise "Cannot apply filesystem compatibility through #{executable}; use a native #{tool} installation."
      end
      settings['DYLD_INSERT_LIBRARIES'] = [row.fetch('fsync_library'), ENV['DYLD_INSERT_LIBRARIES']].compact.join(':')
    end
    if row && tool == 'pnpm' && runs_code?(args, directory(args, tool))
      verify_installed(executable, settings, row, args, directory(args, tool))
    end
    exec(settings, executable, *args)
  end
end

if __FILE__ == $0
  begin
    ProjectTool.run(File.basename($0), ARGV)
  rescue StandardError => error
    warn "Project tools: #{error.message}"
    exit 1
  end
end
