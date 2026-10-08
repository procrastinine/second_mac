require_relative 'core'
require 'securerandom'
require 'pathname'

module AgentVM
  class Projects
    def initialize(vm); @vm = vm; end
    def registry
      File.file?(@vm.file('projects.json')) ? JSON.parse(File.read(@vm.file('projects.json'))) : {'projects'=>[]}
    end
    def mapping(directory)
      root = File.realpath(File.expand_path(directory))
      share = AgentVM.shares(@vm.config).select do |row|
        !row['read_only'] && (root == row['host'] || root.start_with?(row['host'] + '/'))
      end.max_by { |row| row['host'].length }
      raise Error, 'Choose a project inside a writable configured share.' unless share
      [root, File.join(share['guest'], root.delete_prefix(share['host']).sub(%r{\A/}, ''))]
    end
    def tools(root)
      names = []
      package = File.join(root, 'package.json')
      if File.file?(package)
        manifest = JSON.parse(File.read(package))
        names << (File.file?(File.join(root, 'pnpm-lock.yaml')) ||
          File.file?(File.join(root, 'pnpm-workspace.yaml')) ||
          manifest['packageManager'].to_s.start_with?('pnpm@') ? 'pnpm' : 'npm')
      end
      names << 'uv' if File.file?(File.join(root, 'pyproject.toml'))
      raise Error, 'Choose a pnpm/npm/uv project or workspace root.' if names.empty?
      names
    end
    def configure(root, entry, action)
      source = File.read(File.join(__dir__, 'project-tools-setup.rb'))
      request = {'action'=>action, 'root'=>root, 'entry'=>entry,
        'adapter'=>File.read(File.join(__dir__, 'project-tool.rb')),
        'fsync_source'=>File.read(File.join(__dir__, 'fsync-compat.c'))}
      output = yield(source, JSON.generate(request))
      JSON.parse(output)
    end
    def setup(directory)
      host, guest = mapping(directory)
      saved = registry
      entry = saved['projects'].find { |row| row['root'] == host } ||
        {'id'=>SecureRandom.hex(12), 'root'=>host}
      saved['store'] ||= File.join('/Users', 'Shared', '.project-pnpm-' + SecureRandom.hex(12))
      entry = entry.merge('tools'=>tools(host), 'store'=>saved['store'], 'guest'=>guest)
      if entry['tools'].include?('uv')
        share = AgentVM.shares(@vm.config).select { |row| host == row['host'] || host.start_with?(row['host'] + '/') }.max_by { |row| row['host'].length }
        cache = File.join(share['host'], '.project-tools-cache')
        # Cache data must stay out of publication even when the share itself is a repo.
        begin
          git_root = AgentVM.run('/usr/bin/git', '-C', share['host'], 'rev-parse', '--show-toplevel', capture:true).strip
        rescue Error
          git_root = nil
        end
        if git_root
          relative = Pathname.new(cache).relative_path_from(Pathname.new(git_root)).to_s
          tracked = AgentVM.run('/usr/bin/git', '-C', git_root, 'ls-files', '--', relative, capture:true)
          raise Error, 'The private cache path is already tracked by Git.' unless tracked.empty?
          exclude = AgentVM.run('/usr/bin/git', '-C', git_root, 'rev-parse', '--git-path', 'info/exclude', capture:true).strip
          exclude = File.expand_path(exclude, git_root)
          original = File.file?(exclude) ? File.read(exclude) : ''
          pattern = '/' + relative + '/'
          AgentVM.write(exclude, original.rstrip + "\n" + pattern + "\n") unless original.lines.map(&:strip).include?(pattern)
        end
        entry['uv_cache'] = File.join(cache, 'uv')
        entry['python_dir'] = File.join(cache, 'python')
        entry['reuse_existing'] = true
      end
      @vm.start unless @vm.running?
      host_result = configure(host, entry.reject { |key, _| key == 'guest' }, 'setup') do |source, input|
        AgentVM.run('/usr/bin/ruby', '-e', source, input:input, capture:true)
      end
      guest_entry = entry.reject { |key, _| %w[root guest].include?(key) }
      if entry['tools'].include?('uv')
        %w[uv_cache python_dir].each { |key| guest_entry[key] = File.join(share['guest'], entry[key].delete_prefix(share['host']).sub(%r{\A/}, '')) }
        guest_entry['reuse_existing'] = !host_result['reused_environment']
      end
      guest_result = configure(guest, guest_entry, 'setup') do |source, input|
        @vm.ssh('/usr/bin/ruby', '-e', source, input:input, capture:true)
      end
      saved['projects'].reject! { |row| row['root'] == host }
      saved['projects'] << entry
      AgentVM.json_write(@vm.file('projects.json'), saved)
      puts JSON.pretty_generate('host'=>host_result, 'guest'=>guest_result)
      puts 'Configured local project tools on both Macs. Open a new shell, then install normally.'
      puts 'For an existing pnpm tree, run pnpm install --force once to adopt the cache location.' if entry['tools'].include?('pnpm')
      entry
    end
    def remove(directory)
      host, guest = mapping(directory)
      saved = registry
      entry = saved['projects'].find { |row| row['root'] == host }
      raise Error, 'Project is not registered.' unless entry
      @vm.start unless @vm.running?
      configure(guest, entry, 'remove') { |source, input| @vm.ssh('/usr/bin/ruby', '-e', source, input:input, capture:true) }
      configure(host, entry, 'remove') { |source, input| AgentVM.run('/usr/bin/ruby', '-e', source, input:input, capture:true) }
      saved['projects'].reject! { |row| row['root'] == host }
      AgentVM.json_write(@vm.file('projects.json'), saved)
      puts 'Removed local project configuration; dependencies and environments were retained.'
    end
    def command(argv)
      args = argv.dup
      action = args.shift || 'list'
      case action
      when 'list'
        raise Error, 'Usage: vm projects list' unless args.empty?
        puts JSON.pretty_generate(registry['projects'])
      when 'setup', 'remove'
        raise Error, "Usage: vm projects #{action} DIRECTORY" unless args.length == 1
        action == 'setup' ? setup(args.first) : remove(args.first)
      else
        raise Error, 'Usage: vm projects list | setup DIRECTORY | remove DIRECTORY'
      end
    rescue SystemCallError, JSON::ParserError => error
      raise Error, error.message
    end
  end
end
