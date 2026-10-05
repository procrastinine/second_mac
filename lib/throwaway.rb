require_relative 'core'
require_relative 'images'
require_relative 'install'
require 'optparse'
require 'time'

module AgentVM
  # Retained COW copies. Never attach the source VM disk, share, or forwards.
  class Throwaway
    ACTIONS = %w[ssh sudo cp tmux gui mount unmount start stop restart reboot suspend resume status resources password ports network sip permissions ui guest-control microphone audio camera auth].freeze

    def initialize(source_name = nil)
      @source_name = source_name
    end

    def self.entries
      Dir.glob(File.join(AgentVM.state_root, '*', 'config.json')).sort.map do |path|
        next if File.symlink?(path) || File.symlink?(File.dirname(path))
        config = JSON.parse(File.read(path))
        record = config['throwaway']
        next unless record.is_a?(Hash) && record['id'].to_s.match?(/\A[0-9a-f]{8}\z/)
        next unless config['name'] == File.basename(File.dirname(path))
        VM.new(config)
      rescue JSON::ParserError, Error, Errno::ENOENT
        nil
      end.compact
    end

    def find(id)
      found = self.class.entries.select { |vm| vm.config['throwaway']['id'] == id }
      raise Error, 'Unknown or ambiguous throwaway ID. Run vm throwaway list.' unless found.length == 1
      found.first
    end

    def list(json: false)
      rows = self.class.entries.map do |vm|
        vm.config['throwaway'].slice('id', 'source', 'created_at').merge(
          'name'=>vm.name, 'status'=>vm.config['phase'] == 'ready' ? (vm.running? ? 'running' : (vm.suspended? ? 'suspended' : 'stopped')) : 'incomplete',
          'sharing'=>vm.config['sharing'], 'directory'=>vm.tart_directory)
      end
      return puts(JSON.pretty_generate(rows)) if json
      return puts('No retained throwaways.') if rows.empty?
      rows.each do |row|
        puts "#{row['id']}  #{row['name']}  #{row['status']}  from #{row['source']}  #{row['created_at']}"
        puts "  #{row['directory']}"
      end
      puts 'Open: vm throwaway ssh ID | gui ID | mount ID. Remove: vm throwaway delete ID.'
    end

    def create(name: nil)
      source = VM.load(@source_name)
      raise Error, 'Source must be a completed managed VM.' unless source.config['phase'] == 'ready'
      raise Error, 'Finish the source restore before copying it.' if File.exist?(source.file('restore-in-progress.json'))
      copy = nil
      claimed = false
      source.with_lifecycle_lock do
        raise Error, 'Stop the source first with vm stop. Throwaways never interrupt a running SSH session.' if source.running?
        DiskFiles.with_lock(source.tart_directory) do
          id = SecureRandom.hex(4)
          id = SecureRandom.hex(4) while self.class.entries.any? { |vm| vm.config['throwaway']['id'] == id }
          config = JSON.parse(JSON.generate(source.config))
          config.merge!('name'=>name || "throwaway-#{id}", 'phase'=>'copying', 'sharing'=>'none',
                        'share'=>File.join(AgentVM.state_root, 'unused-share'), 'share_read_only'=>true,
                        'menubar'=>false, 'integrations'=>false, 'guest_control'=>false, 'permissions_auto'=>false, 'microphone'=>false, 'audio_output'=>false, 'camera_obs'=>false,
                        'credential_relays'=>[], 'credential_relay_cleanup'=>true,
                        'throwaway'=>{'id'=>id, 'source'=>source.name, 'created_at'=>Time.now.utc.iso8601, 'guest_configured'=>false})
          %w[host_label ports source_vm fresh last_successful_update].each { |key| config.delete(key) }
          copy = VM.new(config)
          raise Error, 'Destination name already exists; choose another --name.' if File.exist?(copy.state) || File.symlink?(copy.state) || File.exist?(copy.tart_directory) || File.symlink?(copy.tart_directory)
          FileUtils.mkdir_p(AgentVM.state_root, mode:0700)
          Dir.mkdir(copy.state, 0700)
          claimed = true
          copy.save
          puts "Creating retained throwaway #{id} (#{copy.name}). Host sharing and port forwards are disabled."
          Images.new(copy).copy_image(source.tart_directory, copy.tart_directory, clone_only:true) do
            %w[admin-password id_ed25519 id_ed25519.pub known-hosts].each do |file|
              path = source.file(file)
              raise Error, 'Required source credential is missing or unsafe.' unless File.file?(path) && !File.symlink?(path)
              content = File.binread(path)
              content = copy.name + ' ' + content.split[1,2].join(' ') + "\n" if file == 'known-hosts'
              AgentVM.write(copy.file(file), content)
            end
          end
          Images.new(copy).randomize
          Installer.new(copy.config, integrations:false).bundle(copy)
          # Copies retain their own management snapshot, never follow the
          # parent's checkout, and never fetch future project releases.
          copy.config['source_directory'] = copy.file('runtime')
          copy.config['source_mode'] = 'local'
          copy.exclude_backup(copy.tart_directory, copy.state)
          copy.render_host
          copy.config['phase'] = 'ready'
          copy.save
        end
      end
      puts "Saved #{copy.config['throwaway']['id']}. It inherits existing guest files and credentials; disk changes stay separate."
      copy
    rescue StandardError
      warn "Incomplete copy retained at #{copy.state}; inspect vm throwaway list." if claimed && copy && File.file?(copy.file('config.json'))
      raise
    end

    def self.configure_guest(vm)
      vm.with_lifecycle_lock do
        files = {
          '/usr/local/libexec/agent-vm/core.rb'=>['lib/core.rb', 0644],
          '/usr/local/libexec/agent-vm/profile-plan.rb'=>['lib/profile-plan.rb', 0644],
          '/usr/local/libexec/agent-vm/mount-share.rb'=>['guest/mount-share.rb', 0755],
          '/usr/local/libexec/agent-vm/network-dns.rb'=>['guest/network-dns.rb', 0644],
          vm.home + '/.local/share/agent-vm/doctor.rb'=>['guest/doctor.rb', 0755]
        }.map { |target, (source, mode)| [target, File.read(vm.file('runtime/' + source)), mode] }
        files << ['/etc/agent-vm/config.json', JSON.pretty_generate(AgentVM.guest_config(vm.config)) + "\n", 0644]
        script = <<~'RUBY'
          require 'json'
          require 'fileutils'
          require 'etc'
          account = Etc.getpwnam(ARGV.fetch(0))
          JSON.parse(STDIN.read).each do |path, content, mode|
            FileUtils.mkdir_p(File.dirname(path))
            temp = path + '.throwaway-tmp'
            File.open(temp, 'w', mode) { |file| file.write(content) }
            File.chmod(mode, temp)
            File.chown(account.uid, account.gid, temp) if path.start_with?(account.dir + '/')
            File.rename(temp, path)
          end
        RUBY
        vm.root('/usr/bin/ruby', '-e', script, '--', vm.config['user'], input:JSON.generate(files))
        vm.ssh('/bin/rm', '-f', vm.home + '/.config/second-mac/control.json')
        vm.root('/usr/bin/ruby', '/usr/local/libexec/agent-vm/mount-share.rb')
        %w[ComputerName LocalHostName HostName].each { |key| vm.root('/usr/sbin/scutil', '--set', key, vm.name) }
        vm.config['throwaway']['guest_configured'] = true
        vm.save
      end
    end

    def run_script(vm, path, args)
      # Copy just the explicitly selected script, never its parent directory.
      content = File.binread(path)
      status = nil
      begin
        vm.start
        directory = vm.ssh('/usr/bin/mktemp', '-d', '/tmp/throwaway-run.XXXXXXXX', capture:true).strip
        raise Error, 'Unexpected guest script directory.' unless directory.match?(%r{\A(?:/private)?/tmp/throwaway-run\.[A-Za-z0-9]+\z})
        remote = directory + '/script'
        vm.ssh('/bin/sh', '-c', 'umask 077; cat > "$1" && chmod 700 "$1"', 'sh', remote, input:content)
        command = content.start_with?('#!') ? [remote, *args] : ['/bin/bash', remote, *args]
        ssh = vm.ssh_args
        ssh << '-t' if $stdin.tty?
        system(*ssh, vm.name, Shellwords.join(command))
        result = $?
        status = result.exitstatus || 128 + result.termsig.to_i
      ensure
        begin
          vm.stop if vm.running?
        rescue Error => error
          warn "Could not shut down the retained throwaway: #{error.message}"
          status = 1 if status == 0
        end
        puts "Retained #{vm.config['throwaway']['id']}; vm throwaway ssh #{vm.config['throwaway']['id']} reopens it."
      end
      status
    end

    def delete(id)
      vm = find(id)
      vm.with_lifecycle_lock do
        raise Error, 'Stop this throwaway first: vm throwaway stop ' + id if vm.running?
        raise Error, 'Resolve saved memory and shut down the throwaway before deleting it.' if vm.suspended? || File.file?(vm.file('suspend.json'))
        raise Error, 'Unsafe throwaway state directory.' if File.symlink?(vm.state) || File.symlink?(vm.tart_directory)
        remove = lambda do
          require_relative 'files'
          require_relative 'permissions'
          Files.new(vm).unmount
          Permissions.new(vm).stop_watcher
          require_relative 'guest-control'
          GuestControl.new(vm).stop
          require_relative 'credentials'
          Credentials.new(vm).stop
          require_relative 'camera'
          Camera.new(vm).stop
          require_relative 'network'
          Network.new(vm).stop_watcher
          system('/bin/launchctl', 'bootout', "#{vm.domain}/#{vm.label}", out:File::NULL, err:File::NULL)
          FileUtils.remove_entry_secure(vm.tart_directory) if File.directory?(vm.tart_directory)
          FileUtils.remove_entry_secure(vm.state)
        end
        if File.file?(File.join(vm.tart_directory, 'config.json'))
          DiskFiles.with_lock(vm.tart_directory) { remove.call }
        else
          remove.call
        end
      end
      puts "Deleted throwaway #{id}. The source VM and host files are unchanged."
    end

    def command(argv)
      args = argv.dup
      action = args.shift
      action = 'list' if action == 'ls'
      if action == 'access'
        require_relative 'access'
        Access.new(find(args.shift)).command(args)
        return 0
      elsif action == 'list'
        raise Error, 'Usage: vm throwaway list [--json]' unless [[], ['--json']].include?(args)
        list(json:args == ['--json'])
        return 0
      elsif action == 'delete'
        raise Error, 'Usage: vm throwaway delete ID' unless args.length == 1
        delete(args.first)
        return 0
      elsif ACTIONS.include?(action)
        vm = find(args.shift)
        raise Error, 'Copy setup is incomplete; inspect its state or delete it and retry.' unless vm.config['phase'] == 'ready'
        cli = vm.file('runtime/lib/cli.rb')
        raise Error, 'The throwaway management snapshot is missing; restore its private state from backup.' unless File.file?(cli)
        exec('/usr/bin/ruby', cli, '--name', vm.name, action, *args)
      end
      args.unshift(action) unless action.nil? || action == 'create'
      name = nil
      parser = OptionParser.new do |o|
        o.banner = 'Usage: vm throwaway [create] [--name NAME] [SCRIPT [ARG...]]'
        o.separator 'Creates a retained copy of the stopped source. No shares, forwards, downloads or automatic deletion.'
        o.separator 'Manage: vm throwaway list [--json] | access ID [--json] | ssh ID [CMD] | sudo ID CMD | cp ID SRC... DEST | gui ID | mount ID | stop ID | delete ID'
        o.on('--name NAME', 'Optional VM name; every copy also gets a short ID') { |value| name = value }
        o.on('-h', '--help') { puts o; return 0 }
      end
      parser.order!(args)
      path = args.shift
      if path && (!File.file?(path) || !File.readable?(path))
        unless path.include?('/') || path.include?('.')
          raise Error, "Unknown throwaway command: #{path}. Commands: create, list, delete, #{ACTIONS.join(', ')}; or a SCRIPT file to run in a new copy."
        end
        raise Error, "Script must be a readable local file: #{path}"
      end
      source = VM.load(@source_name)
      checkout = source.config['source_directory']
      if checkout && File.file?(File.join(checkout, 'lib/cli.rb')) && File.expand_path(checkout) != File.expand_path('..', __dir__)
        exec('/usr/bin/ruby', File.join(checkout, 'lib/cli.rb'), '--name', source.name, 'throwaway', *argv)
      end
      copy = create(name:name)
      path ? run_script(copy, path, args) : 0
    rescue OptionParser::ParseError => error
      raise Error, error.message
    end
  end
end
