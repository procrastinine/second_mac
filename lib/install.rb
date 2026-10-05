#!/usr/bin/ruby
require_relative 'core'
require_relative 'images'
require_relative 'host-path'
require_relative 'first-boot'
require 'tmpdir'
require 'fiddle'

module AgentVM
  class Installer
    def initialize(config, update: false, integrations: true)
      @config = config
      @update = update
      @integrations = integrations && config.fetch('integrations', true)
      @source = File.expand_path('..', __dir__)
      @cache = File.join(AgentVM.state_root, 'downloads')
    end

    def download(url, path)
      raise Error, 'Download URL must use HTTPS' unless url.start_with?('https://')
      FileUtils.mkdir_p(File.dirname(path), mode: 0700)
      temp = path + ".#{Process.pid}.#{SecureRandom.hex(6)}.download"
      AgentVM.run('/usr/bin/curl', '--fail', '--location', '--show-error', '--silent', '--retry', '3',
                  '--connect-timeout', '20', '--max-time', '600', '--proto', '=https', '--proto-redir', '=https',
                  url, '-o', temp)
      File.rename(temp, path)
    ensure
      File.unlink(temp) if temp && File.exist?(temp)
    end

    def replace_directory(incoming, destination)
      raise Error, 'Managed directory must not be a symlink or regular file.' if File.symlink?(destination) || (File.exist?(destination) && !File.directory?(destination))
      if File.directory?(destination)
        swap = Fiddle::Function.new(Fiddle::Handle::DEFAULT['renamex_np'],
                                   [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
        raise Error, "Could not replace managed directory: #{SystemCallError.new('renamex_np', Fiddle.last_error).message}" unless swap.call(incoming, destination, 2).zero? # RENAME_SWAP
      else
        File.rename(incoming, destination)
      end
    end

    def release(repo, asset_name, destination)
      FileUtils.mkdir_p(@cache, mode:0700)
      File.open(File.join(@cache, repo + '.lock'), File::RDWR|File::CREAT, 0600) do |lock|
        raise Error, "Another installation is fetching #{repo}; retry when it finishes." unless lock.flock(File::LOCK_EX|File::LOCK_NB)
        release_unlocked(repo, asset_name, destination)
      end
    end

    def release_unlocked(repo, asset_name, destination)
      metadata = File.join(@cache, repo + '-release.json')
      download("https://api.github.com/repos/openai/#{repo}/releases/latest", metadata)
      info = JSON.parse(File.read(metadata))
      asset = info.fetch('assets').find { |a| a['name'] == asset_name }
      raise Error, "Latest #{repo} release has no #{asset_name}" unless asset
      digest = asset['digest'].to_s
      raise Error, "#{repo} release has no SHA-256 digest; cannot verify download" unless digest.match?(/\Asha256:[0-9a-f]{64}\z/)
      archive = File.join(@cache, "#{repo}-#{info.fetch('tag_name')}.tar.gz")
      unless File.file?(archive) && 'sha256:' + Digest::SHA256.file(archive).hexdigest == digest
        download(asset.fetch('browser_download_url'), archive)
      end
      raise Error, "#{repo} download checksum mismatch" unless 'sha256:' + Digest::SHA256.file(archive).hexdigest == digest
      target = File.join(@cache, "#{repo}-#{info.fetch('tag_name')}")
      marker = File.join(target, '.archive-sha256')
      unless File.file?(File.join(target, destination)) && File.file?(marker) && File.read(marker) == digest
        incoming = Dir.mktmpdir('.release-', @cache)
        AgentVM.run('/usr/bin/tar', '-xzf', archive, '-C', incoming)
        raise Error, "#{repo} archive is missing #{destination}" unless File.file?(File.join(incoming, destination))
        AgentVM.write(File.join(incoming, '.archive-sha256'), digest)
        replace_directory(incoming, target)
      end
      @config[repo.tr('-', '_') + '_version'] = info['tag_name']
      File.join(target, destination)
    ensure
      FileUtils.remove_entry(incoming) if incoming && File.directory?(incoming)
    end

    def host_tools
      raise Error, 'Run as your normal macOS account, not sudo/root.' if Process.uid.zero?
      raise Error, 'Apple Silicon is required.' unless AgentVM.run('/usr/bin/uname', '-m', capture: true).strip == 'arm64'
      os = AgentVM.run('/usr/bin/sw_vers', '-productVersion', capture: true).strip
      raise Error, 'macOS 26 or later is required for ASIF disk storage.' if os.split('.').first.to_i < 26
      raise Error, 'Install Homebrew first: https://brew.sh (and finish its Command Line Tools installation).' unless File.executable?('/opt/homebrew/bin/brew')
      AgentVM.run('/opt/homebrew/bin/brew', 'analytics', 'off')
      ram = AgentVM.run('/usr/sbin/sysctl', '-n', 'hw.memsize', capture: true).to_i / 1024**3
      cores = AgentVM.run('/usr/sbin/sysctl', '-n', 'hw.ncpu', capture: true).to_i
      raise Error, "Reserve at least 4 GiB for the host; use --memory #{[ram - 4, 4].max}." if @config['memory_gb'] > ram - 4
      raise Error, "This host has #{cores} CPUs; reduce --cpus." if @config['cpus'] > cores
      if @update || !File.executable?('/opt/homebrew/bin/softnet')
        AgentVM.run('/opt/homebrew/bin/brew', 'update')
        AgentVM.run('/opt/homebrew/bin/brew', 'install', 'openai/tools/softnet')
        AgentVM.run('/opt/homebrew/bin/brew', 'upgrade', 'openai/tools/softnet') if @update
      end
      softnet = File.realpath('/opt/homebrew/bin/softnet')
      st = File.stat(softnet)
      unless st.uid.zero? && st.setuid? && (st.mode & 0022).zero?
        authorize_softnet(softnet)
      end
      @config['tart'] = release('tart', 'tart.tar.gz', 'tart.app/Contents/MacOS/tart')
      @config['guest_agent'] = release('tart-guest-agent', 'tart-guest-agent-darwin-all.tar.gz', 'tart-guest-agent')
      AgentVM.run('/usr/bin/codesign', '--verify', '--deep', '--strict', File.expand_path('../../..', @config['tart']))
      help = AgentVM.run(@config['tart'], 'run', '--help', capture: true)
      %w[--net-softnet-block --no-usb-accessories].each do |flag|
        raise Error, "Current Tart does not support #{flag}" unless help.include?(flag)
      end
      sharing_tools
    end

    def authorize_softnet(path, interactive: $stdin.tty?)
      puts 'Softnet needs administrator authorization for its new networking executable.'
      command = Shellwords.join(['/usr/sbin/chown', 'root:wheel', path]) + ' && ' +
        Shellwords.join(['/bin/chmod', '4755', path])
      if interactive
        AgentVM.run('/usr/bin/sudo', '/bin/sh', '-c', command)
      else
        puts 'Approve the macOS administrator prompt to continue. Canceling leaves installation resumable.'
        script = "on run argv\n  do shell script (item 1 of argv) with administrator privileges\nend run"
        AgentVM.run('/usr/bin/osascript', '-e', script, command, capture:true, timeout:600)
      end
      st = File.stat(path)
      raise Error, 'Softnet administrator setup was not completed; rerun this command to resume.' unless st.uid.zero? && st.setuid? && (st.mode & 0022).zero?
    end

    def sharing_tools
      return unless AgentVM.share_entries(@config).any? { |entry| entry['kind'] == 'macfuse' }
      unless File.file?('/usr/local/lib/libfuse.2.dylib')
        AgentVM.run('/opt/homebrew/bin/brew', 'install', '--cask', 'macfuse')
        raise Error, 'macFUSE installed on the host. Enable its kernel backend using https://github.com/macfuse/macfuse/wiki/Getting-Started, restart macOS, then rerun this command. No guest macFUSE is needed.'
      end
      uv = ['/opt/homebrew/bin/uv', File.join(Dir.home,'.local/bin/uv')].find { |p| File.executable?(p) }
      unless uv
        AgentVM.run('/opt/homebrew/bin/brew', 'install', 'uv')
        uv = '/opt/homebrew/bin/uv'
      end
      environment = File.join(AgentVM.state_root, 'host-tools')
      AgentVM.run(uv, 'venv', environment) unless File.executable?(File.join(environment,'bin/python'))
      AgentVM.run(uv, 'pip', 'install', '--upgrade', '--python', File.join(environment,'bin/python'),
                  '-r', File.join(@source,'packages/host-python.txt'))
      @config['share_python'] = File.join(environment,'bin/python')
    end

    def sharing_directories(vm)
      AgentVM.share_entries(vm.config).each { |entry| FileUtils.mkdir_p(entry['host'], mode:0700) }
      AgentVM.shares(vm.config)
    end

    def bundle(vm)
      bundle = vm.file('runtime')
      FileUtils.mkdir_p(vm.state, mode:0700)
      manifest = source_manifest
      installed = vm.file('source-manifest.json')
      unchanged = File.file?(installed) && JSON.parse(File.read(installed)) == manifest &&
        manifest.all? { |path, hash| File.file?(File.join(bundle, path)) && !File.symlink?(File.join(bundle, path)) &&
          Digest::SHA256.file(File.join(bundle, path)).hexdigest == hash && (File.stat(File.join(bundle, path)).mode & 0777) == (File.stat(File.join(@source, path)).mode & 0777) } &&
        source_manifest(bundle) == manifest
      @bundle_changed = !unchanged
      unless File.expand_path(bundle) == @source || unchanged
        raise Error, 'Installed runtime must be a regular directory.' if File.symlink?(bundle) || (File.exist?(bundle) && !File.directory?(bundle))
        incoming = Dir.mktmpdir('.runtime-', vm.state)
        %w[lib guest packages].each do |directory|
          FileUtils.cp_r(File.join(@source, directory), incoming)
        end
        %w[agent-vm install.sh bootstrap.sh update.sh].each { |file| FileUtils.cp(File.join(@source, file), incoming) }
        # Menu polling must never see a missing or half-copied runtime tree.
        replace_directory(incoming, bundle)
      end
      vm.config['source_directory'] = @source unless @source == File.expand_path(bundle)
      AgentVM.json_write(installed, manifest) unless unchanged
      # Obsolete raw-path sharing manifests must not survive migration.
      File.unlink(vm.file('shares.json')) if File.file?(vm.file('shares.json'))
      vm.save
      bundle
    ensure
      FileUtils.remove_entry(incoming) if incoming && File.directory?(incoming)
    end

    def bundle_changed?; @bundle_changed; end

    def source_manifest(directory = @source)
      manifest = {}
      %w[lib guest packages].each do |part|
        Dir.glob(File.join(directory, part, '**', '*')).sort.each do |path|
          next unless File.file?(path)
          relative = path.delete_prefix(directory + '/')
          next if %w[guest/config.json guest/homebrew-install.sh guest/tart-guest-agent].include?(relative)
          manifest[relative] = Digest::SHA256.file(path).hexdigest
        end
      end
      %w[agent-vm install.sh bootstrap.sh update.sh].each { |file| manifest[file] = Digest::SHA256.file(File.join(directory, file)).hexdigest }
      manifest
    end

    def stage(vm, ip = nil, bootstrap: true)
      bundle = bundle(vm)
      FileUtils.cp(vm.config['guest_agent'], File.join(bundle, 'guest', 'tart-guest-agent'))
      download('https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh', File.join(bundle, 'guest', 'homebrew-install.sh')) if bootstrap
      AgentVM.json_write(File.join(bundle, 'guest', 'config.json'), AgentVM.guest_config(vm.config))
      destination = "#{vm.home}/.cache/agent-vm-setup"
      if ip
        vm.bootstrap_ssh(ip, '/bin/mkdir', '-p', destination)
        options, target = vm.bootstrap_args(ip), "#{vm.config['user']}@#{ip}"
      else
        vm.ssh('/bin/mkdir', '-p', destination)
        options, target = ['-F', vm.file('ssh-config')], vm.name
      end
      AgentVM.run('/usr/bin/scp', *options, '-r', File.join(bundle, 'guest'), File.join(bundle, 'packages'), File.join(bundle, 'lib'), "#{target}:#{destination}/")
    end

    def apply_configuration(vm, prepare_host: true, integrations: true)
      raise Error, 'Managed configuration updates exclude retained throwaways. Update the main VM and create a new copy instead.' if vm.config['throwaway']
      sharing_tools if prepare_host
      sharing_directories(vm)
      vm.start(share:false, managed_updates:false)
      vm.with_lifecycle_lock do
        vm.save
        stage(vm, bootstrap:false)
        setup = vm.home + '/.cache/agent-vm-setup/guest/'
        vm.ssh('/bin/bash', setup + 'apply-config.sh', timeout:300)
        vm.root('/usr/bin/ruby', setup + 'finalize.rb')
        vm.root('/usr/bin/ruby', setup + 'setup-smb.rb', vm.config['user'], input:vm.password + "\n")
        vm.root('/usr/bin/ruby', setup + 'setup-login.rb', input:vm.password + "\n")
        vm.sync_shares
        vm.exclude_backup
        vm.render_host
        vm.ssh('/usr/bin/ruby', vm.home + '/.local/share/agent-vm/doctor.rb', timeout:60)
        vm.ssh('/bin/rm', '-rf', vm.home + '/.cache/agent-vm-setup')
        self.integrations(vm) if integrations
        if integrations && vm.config['menubar']
          require_relative 'menu'
          AgentVM::Menu.new(vm).install
        end
        require_relative 'guest-update'
        GuestUpdate.new(vm).record_configuration
        vm.start_services if integrations
        puts 'Applied the shared configuration without restarting the guest.'
      end
    end

    def integrations(vm)
      return unless @integrations
      ssh_dir = File.join(Dir.home, '.ssh')
      FileUtils.mkdir_p(ssh_dir, mode: 0700)
      ssh_path = File.join(ssh_dir, 'config')
      include_line = 'Include ' + vm.file('ssh-config').gsub('%', '%%').dump
      original = File.exist?(ssh_path) ? File.read(ssh_path) : ''
      unless original.lines.any? { |l| l.strip == include_line }
        # Only insert our include; preserve all existing host blocks verbatim.
        AgentVM.write(vm.file('ssh-config.before-install'), original) unless File.exist?(vm.file('ssh-config.before-install'))
        AgentVM.write(ssh_path, "#{include_line}\nHost *\n\n#{original}")
      end
      marker = '# Managed by agent-vm installer'
      script = "#!/bin/sh\n#{marker}\nexport AGENT_VM_HOME=#{Shellwords.escape(AgentVM.state_root)}\nexec /usr/bin/ruby #{Shellwords.escape(vm.file('runtime/lib/cli.rb'))} \"$@\"\n"
      %w[agent-vm vm].each do |name|
        entry = File.join(Dir.home, '.local/bin', name)
        if File.exist?(entry) && !File.read(entry).include?(marker)
          warn "Existing #{entry} retained; use agent-vm or ./agent-vm instead."
          next
        end
        AgentVM.write(entry, script, 0755)
      end
      HostPath.install(vm)
      require_relative 'host-completion'
      HostCompletion.install(vm)
    end

    def credentials(vm)
      %w[admin-password id_ed25519].each do |name|
        next if File.file?(vm.file(name)) && File.size(vm.file(name)) > 0
        raise Error, "Installation credential #{name} is missing; the existing guest was preserved." if vm.exists?
        if name == 'admin-password'
          AgentVM.write(vm.file(name), SecureRandom.hex(24) + "\n")
        else
          Dir.mktmpdir('.ssh-key-', vm.state) do |directory|
            path = File.join(directory, 'key')
            AgentVM.run('/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', "#{vm.name}-host-only", '-f', path)
            AgentVM.write(vm.file(name), File.binread(path))
          end
        end
      end
      # Recover a shutdown between saving the private and public halves. Never
      # replace the private key or password when resuming an installation.
      public_key = AgentVM.run('/usr/bin/ssh-keygen', '-y', '-P', '', '-f', vm.file('id_ed25519'), capture:true, timeout:15).split[0,2].join(' ')
      path = vm.file('id_ed25519.pub')
      unless File.file?(path) && File.read(path).split[0,2].join(' ') == public_key
        AgentVM.write(path, public_key + " #{vm.name}-host-only\n")
      end
    end

    def install_step(vm, name)
      vm.config['completed_install_steps'] ||= []
      return if vm.config['completed_install_steps'].include?(name)
      vm.config['install_step'] = name
      vm.save
      yield
      vm.config['completed_install_steps'] << name
      vm.config.delete('install_step')
      vm.save
    end

    def finish_installation(vm)
      integrations(vm)
      if vm.config['menubar']
        require_relative 'menu'
        AgentVM::Menu.new(vm).install
      end
      AgentVM.write(File.join(AgentVM.state_root, 'default'), vm.name + "\n") unless File.exist?(File.join(AgentVM.state_root, 'default'))
      vm.config['phase'] = 'ready'
      vm.config['last_successful_install'] = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
      vm.save
      puts "\nReady: #{vm.name}, guest user #{vm.config['user']}"
      puts "Connect: #{File.join(@source, 'agent-vm')} --name #{vm.name} ssh"
      puts "Installed versions: #{vm.file('versions.txt')}"
    end

    def collect_versions(vm)
      path = vm.home + '/.local/share/agent-vm/versions.txt'
      versions = vm.ssh('/bin/sh', '-c', 'if [ -f "$1" ]; then cat "$1"; fi', 'inventory', path, capture:true)
      unless versions.empty?
        AgentVM.write(vm.file('versions.txt'), "Tart: #{vm.config['tart_version']}\nGuest agent: #{vm.config['tart_guest_agent_version']}\n#{versions}")
      end
      # A retry after removal must use the saved host inventory, without
      # repeating completed package installation to recreate a temporary file.
      raise Error, 'Installation inventory is missing from both machines.' unless File.file?(vm.file('versions.txt'))
      vm.ssh('/bin/rm', '-f', path, capture:true)
    end

    def prepare_ui_while(vm)
      return yield unless vm.needs_custom_tart?
      require_relative 'ui-build'
      builder = UIBuild.new(vm)
      return yield if builder.ready?
      puts 'Building optional guest UI/audio support alongside macOS image preparation.'
      puts "Build output: #{vm.file('ui-build.log')}"
      worker = Thread.new do
        Thread.current.report_on_exception = false
        File.open(vm.file('ui-build.log'), 'w', 0600) do |log|
          log.sync = true
          Thread.current[:agent_vm_command_log] = log
          builder.install
        end
      end
      result = yield
      vm.config['ui_tart'] = worker.value
      vm.save
      puts 'Guest UI/audio build and macOS image preparation are complete.'
      result
    ensure
      # Preserve completed OS/build caches, but never leave a compiler running
      # after an interrupted install. AgentVM.run reaps its process group.
      if worker && worker.alive?
        worker.kill
        worker.join
      end
    end

    def run
      vm = VM.new(@config)
      saved = File.file?(vm.file('config.json'))
      if vm.exists? && !saved
        raise Error, "A VM named #{vm.name} already exists and is not owned by this installer. Choose another --name."
      end
      if saved && !%w[preparing creating cloning].include?(vm.config['phase']) && !vm.exists?
        raise Error, 'The configured VM disk is missing. Restore it, or choose a new --name to create another VM.'
      end
      FileUtils.mkdir_p(vm.state, mode: 0700)
      File.chmod(0700, vm.state)
      lock = File.open(vm.file('install.lock'), File::RDWR | File::CREAT, 0600)
      raise Error, 'Another installation is running for this VM.' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      if saved && vm.exists? && vm.config['phase'] == 'ready'
        apply_configuration(vm)
        puts "Ready: #{vm.name}. Existing OS, guest packages and credentials retained."
        return
      end
      puts "Resuming #{vm.name}: #{vm.config['install_step'] || vm.config['phase']}." if saved
      if saved && vm.config['phase'] == 'integrating'
        finish_installation(vm)
        return
      end
      unless saved
        vm.config['phase'] = 'preparing'
        vm.config['source_directory'] = @source
        vm.save
      end
      credentials(vm)
      host_tools
      sharing_directories(vm) # Validate before creating or booting the guest.
      vm.config['phase'] = 'creating' if vm.config['phase'] == 'preparing'
      vm.save
      FileUtils.mkdir_p(vm.file('runtime/lib'))
      FileUtils.cp_r(File.join(@source, 'lib', '.'), vm.file('runtime/lib')) unless File.expand_path(vm.file('runtime')) == @source
      vm.render_host
      prepare_ui_while(vm) do
        unless vm.exists?
          images = Images.new(vm)
          if vm.config['source_vm']
            vm.config['phase'] = 'cloning'
            vm.save
            images.clone_managed(vm.config['source_vm'])
          elsif !images.reuse
            puts "Creating #{vm.name} from Apple's restore image (this can take a while)."
            AgentVM.run(vm.tart, 'create', vm.name, '--from-ipsw', images.restore_source, '--disk-size', vm.config['disk_gb'].to_s, '--disk-format', 'asif')
            images.cache
          end
        end
      end
      if vm.config['phase'] == 'cloning'
        Images.new(vm).randomize
        vm.config['phase'] = 'cloned'
        vm.save
      end
      if vm.config['phase'] == 'cloned'
        AgentVM.run(vm.tart, 'set', vm.name, '--cpu', vm.config['cpus'].to_s, '--memory', (vm.config['memory_gb'] * 1024).to_s)
        apply_configuration(vm, prepare_host:false)
        vm.config['phase'] = 'ready'
        vm.save
        AgentVM.write(File.join(AgentVM.state_root, 'default'), vm.name + "\n") unless File.exist?(File.join(AgentVM.state_root, 'default'))
        puts "Ready: #{vm.name}. The selected existing OS, packages and guest data were retained."
        return
      end
      if vm.config['phase'] == 'creating'
        FirstBoot.new(vm).prepare
        Images.new(vm).randomize
        AgentVM.run(vm.tart, 'set', vm.name, '--cpu', vm.config['cpus'].to_s, '--memory', (vm.config['memory_gb'] * 1024).to_s)
        vm.config['phase'] = 'bootstrap'
        vm.save
      end
      vm.exclude_backup
      if %w[creating bootstrap].include?(vm.config['phase'])
        first_boot = FirstBoot.new(vm)
        first_boot.launch
        ip, port = nil, 22
        rpc_ready = false
        if File.file?(vm.file('known-hosts'))
          begin
            vm.ssh('/usr/bin/true', timeout:15, capture:true)
            rpc_ready = true
          rescue Error
          end
        end
        unless rpc_ready
          waiting = first_boot.awaiting_account? ? 'Waiting for Setup Assistant and Remote Login; rerun the installer to resume if interrupted' : 'Waiting for first boot'
          vm.wait_for(first_boot.awaiting_account? ? 1800 : 900, waiting) do
            require_relative 'network'
            ip, port = Network.new(vm).bootstrap_endpoint
            next false unless ip.match?(/\A\d{1,3}(?:\.\d{1,3}){3}\z/)
            AgentVM.run('/usr/bin/nc', '-z', '-G', '2', ip, port.to_s, capture: true, timeout: 5)
            true
          end
          first_boot.authenticate(ip, port)
        end
        setup = "#{vm.home}/.cache/agent-vm-setup"
        setup_lock = vm.home + '/.cache/agent-vm-install.lock'
        transport = lambda do |*args, **options|
          ip ? vm.bootstrap_ssh(ip, *args, **options) : vm.ssh(*args, **options)
        end
        # A guest installer can outlive its SSH client. Do not replace its
        # staging files or launch a second package installation while it runs.
        transport.call('/usr/bin/ruby', '-e', File.read(File.join(@source, 'guest/setup-lock.rb')), setup_lock, '--check', timeout:15)
        stage(vm, ip)
        locked = ['/usr/bin/ruby', setup + '/guest/setup-lock.rb', setup_lock]
        install_step(vm, 'guest_base') do
          transport.call('/usr/bin/sudo', '-k', '-S', '-p', '', *locked, '/bin/bash', setup + '/guest/bootstrap.sh',
                         input: vm.password + "\n", timeout: 3600)
        end
        # Install the private guest password helper before optional system PKGs
        # (such as TeX Live) need noninteractive sudo through Homebrew.
        install_step(vm, 'guest_credentials') do
          transport.call('/usr/bin/sudo', '-k', '-S', '-p', '', *locked, '/usr/bin/ruby', setup + '/guest/setup-login.rb',
                         input: vm.password + "\n" + vm.password + "\n", timeout:180)
        end
        install_step(vm, 'guest_tools') do
          transport.call(*locked, '/bin/bash', setup + '/guest/install-tools.sh', timeout: 7200)
        end
        # Save the trusted host key before switching off network SSH. A retry
        # can then use VirtIO if interrupted during finalization.
        key = transport.call('/bin/cat', '/etc/ssh/ssh_host_ed25519_key.pub', capture: true).split[0, 2].join(' ')
        AgentVM.write(vm.file('known-hosts'), "#{vm.name} #{key}\n")
        install_step(vm, 'guest_finalize') do
          transport.call('/usr/bin/sudo', '-k', '-S', '-p', '', *locked, '/usr/bin/ruby', setup + '/guest/finalize.rb',
                         input: vm.password + "\n", timeout: 180)
        end
        install_step(vm, 'guest_files') { vm.root(*locked, '/usr/bin/ruby', setup + '/guest/setup-smb.rb', vm.config['user'], input: vm.password + "\n") }
        install_step(vm, 'guest_login') { vm.root(*locked, '/usr/bin/ruby', setup + '/guest/setup-login.rb', input: vm.password + "\n") }
        vm.config['phase'] = 'configured'
        vm.save
        vm.stop
      elsif vm.config['phase'] == 'configured'
        # A previous run may have ended between finalizing the guest and
        # stopping the first-boot Tart process. Finish that network transition.
        vm.stop
      end
      vm.start
      vm.ssh('/usr/bin/ruby', vm.home + '/.local/share/agent-vm/doctor.rb', timeout:60)
      vm.ssh('/bin/rm', '-rf', "#{vm.home}/.cache/agent-vm-setup", timeout: 30)
      collect_versions(vm)
      require_relative 'guest-update'
      GuestUpdate.new(vm).record_configuration
      vm.config['phase'] = 'integrating'
      vm.save
      finish_installation(vm)
    rescue Error => e
      raise Error, "#{e.message}\nInstallation progress is saved. Rerun install.sh --name #{vm.name} from the same checkout after resolving the error." if vm && File.file?(vm.file('config.json'))
      raise
    ensure
      lock.close if lock
    end
  end
end
