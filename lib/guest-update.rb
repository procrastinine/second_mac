require_relative 'core'

module AgentVM
  # Reconcile the latest desired configuration, not a queue of release scripts.
  # Receipts live in the guest so snapshots retain their actual applied version.
  # The host caches a receipt only to avoid booting an unchanged stopped guest.
  class GuestUpdate
    RECEIPT = '/etc/agent-vm/applied-updates.json'.freeze
    def initialize(vm); @vm = vm; end
    def source; File.expand_path('..', __dir__); end
    def fingerprint(paths, settings = {})
      files = paths.sort.to_h { |path| [path, Digest::SHA256.file(File.join(source, path)).hexdigest] }
      Digest::SHA256.hexdigest(JSON.generate([files, settings.sort.to_h]))
    end
    def desired
      guest = Dir.glob(File.join(source, 'guest', '**', '*')).select { |path| File.file?(path) }
                 .map { |path| path.delete_prefix(source + '/') }
      guest -= %w[guest/config.json guest/homebrew-install.sh guest/tart-guest-agent guest/camera-sink.m guest/camera-receiver.rb]
      {
        'configuration'=>fingerprint(guest + %w[lib/core.rb lib/profile-plan.rb lib/autologin.rb lib/guest-update.rb],
                                     AgentVM.guest_config(@vm.config).merge('transport_version'=>@vm.config['tart_guest_agent_version'])),
        'helpers'=>fingerprint(%w[guest/control-client.rb guest/install-control.rb lib/core.rb lib/profile-plan.rb lib/permissions.rb],
                               'user'=>@vm.config['user'], 'ui_enabled'=>@vm.config['ui_enabled']),
        'camera'=>fingerprint(%w[guest/camera-sink.m guest/camera-receiver.rb lib/camera.rb])
      }
    end
    def disk_identity
      metadata = File.stat(File.join(@vm.tart_directory, 'disk.img'))
      [metadata.dev, metadata.ino]
    end
    def cached
      value = JSON.parse(File.read(@vm.file('guest-update-state.json')))
      value.is_a?(Hash) && value['disk_identity'] == disk_identity ? value : {}
    rescue Errno::ENOENT, JSON::ParserError
      {}
    end
    def pending?
      value = cached
      wanted = desired
      wanted.delete('camera') unless value['camera_installed'] || @vm.config['camera_obs']
      wanted.any? { |key, digest| value.fetch('applied', {})[key] != digest }
    end
    def probe
      value = @vm.ssh('/usr/bin/ruby', '-rjson', '-rdigest', '-e', <<~'RUBY', capture:true)
        path = '/etc/agent-vm/applied-updates.json'
        begin
          applied = File.file?(path) ? JSON.parse(File.read(path)) : {}
          applied = {} unless applied.is_a?(Hash)
        rescue JSON::ParserError
          applied = {}
        end
        base = '/usr/local/libexec/agent-vm/'
        helpers = %w[control-client.rb core.rb profile-plan.rb].to_h do |name|
          file = base + name
          [name, File.file?(file) && !File.symlink?(file) ? Digest::SHA256.file(file).hexdigest : nil]
        end
        command = File.join(Dir.home, '.local/bin/mac-control')
        helpers['command'] = File.file?(command) && !File.symlink?(command) && File.executable?(command) ? Digest::SHA256.file(command).hexdigest : nil
        puts JSON.generate('applied'=>applied, 'helpers'=>helpers,
          'camera_installed'=>%w[camera-sink camera-receiver.rb].any? { |name| File.exist?(base + name) })
      RUBY
      JSON.parse(value)
    end
    def helpers_current?(actual)
      {'control-client.rb'=>'guest/control-client.rb', 'core.rb'=>'lib/core.rb', 'profile-plan.rb'=>'lib/profile-plan.rb',
       'command'=>'guest/control-client.rb'}.all? do |name, path|
        actual[name] == Digest::SHA256.file(File.join(source, path)).hexdigest
      end
    end
    def checkpoint(value)
      @vm.root('/usr/bin/ruby', '-rjson', '-rsecurerandom', '-e', <<~'RUBY', input:JSON.generate(value.fetch('applied')))
        directory = '/etc/agent-vm'
        metadata = File.lstat(directory)
        raise 'Unsafe update receipt directory' unless metadata.directory? && metadata.uid.zero? && (metadata.mode & 0022).zero?
        value = JSON.parse(STDIN.read)
        path = File.join(directory, 'applied-updates.json')
        temporary = path + '.' + SecureRandom.hex(8)
        begin
          File.open(temporary, File::WRONLY|File::CREAT|File::EXCL, 0644) { |file| file.write(JSON.generate(value) + "\n"); file.flush; file.fsync }
          File.chmod(0644, temporary)
          File.rename(temporary, path)
        ensure
          File.unlink(temporary) if File.file?(temporary)
        end
      RUBY
      cache(value)
    end
    def cache(value)
      saved = value.select { |key, _| %w[applied camera_installed].include?(key) }.merge('disk_identity'=>disk_identity)
      path = @vm.file('guest-update-state.json')
      AgentVM.json_write(path, saved) unless cached == saved
    end
    def record_configuration
      value, wanted = probe, desired
      value.fetch('applied')['configuration'] = wanted['configuration']
      value['applied']['helpers'] = wanted['helpers'] if helpers_current?(value.fetch('helpers'))
      checkpoint(value)
    end
    def synchronize
      return unless @vm.config['phase'] == 'ready'
      return if @vm.config['throwaway']
      File.open(@vm.file('guest-update.lock'), File::RDWR|File::CREAT, 0600) do |lock|
        raise Error, 'Guest configuration update is already in progress; retry when it finishes.' unless lock.flock(File::LOCK_EX|File::LOCK_NB)
        wanted, value = desired, probe
        applied = value.fetch('applied')
        changed = false
        if applied['configuration'] != wanted['configuration']
          require_relative 'install'
          Installer.new(@vm.config).apply_configuration(@vm, prepare_host:false, integrations:false)
          value = probe
          applied = value.fetch('applied')
          raise Error, 'Guest configuration did not finish applying; retry the update.' unless applied['configuration'] == wanted['configuration']
          changed = true
        end
        if applied['helpers'] != wanted['helpers'] || !helpers_current?(value.fetch('helpers'))
          require_relative 'permissions'
          Permissions.new(@vm).install_client
          applied['helpers'] = wanted['helpers']
          checkpoint(value)
          changed = true
        end
        if value['camera_installed'] && applied['camera'] != wanted['camera']
          require_relative 'camera'
          camera = Camera.new(@vm)
          active = camera.active?
          camera.stop if active
          camera.install_helpers
          camera.start if active
          applied['camera'] = wanted['camera']
          checkpoint(value)
          changed = true
        end
        cache(value)
        puts(changed ? 'Managed guest configuration and installed helpers updated.' : 'Managed guest configuration and helpers are already current.')
        changed
      end
    end
  end
end
