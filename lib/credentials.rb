require_relative 'core'
require_relative 'model-relay-api'
require_relative 'service-modes'
require 'io/console'

module AgentVM
  class HostCredentials
    def self.path; File.join(AgentVM.state_root, 'credentials/openrouter.key'); end
    def self.prepare
      FileUtils.mkdir_p(File.dirname(path), mode:0700)
      File.chmod(0700, File.dirname(path))
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0600) {} unless File.exist?(path) || File.symlink?(path)
      raise Error, 'Host key must be a regular, user-owned file.' unless File.lstat(path).file? && File.stat(path).uid == Process.uid
      File.chmod(0600, path)
      path
    end
    def self.read
      stat = File.lstat(path)
      raise Error, 'Host key must be a private, user-owned regular file.' unless stat.file? && stat.uid == Process.uid && (stat.mode & 0077).zero?
      key = File.read(path).strip
      raise Error, 'Add an OpenRouter key with vm auth set first.' if key.empty?
      raise Error, 'Host key must contain a single API key.' if key.match?(/\s/) || key.bytesize > 8192
      key
    rescue Errno::ENOENT
      raise Error, 'Add an OpenRouter key with vm auth set first.'
    end
    def self.available?
      read
      true
    rescue Error, SystemCallError
      false
    end
    def self.store(key)
      key = key.strip
      raise Error, 'Enter a single OpenRouter API key.' if key.empty? || key.match?(/\s/) || key.bytesize > 8192
      prepare
      AgentVM.write(path, key + "\n")
    end
    def self.prompt(optional:false, replace:false)
      return true if available? && !replace
      console = IO.console
      unless console
        raise Error, 'Run vm auth set in a terminal, or edit the file with vm auth host.' unless optional
        warn 'No OpenRouter key supplied; setup will continue. Add it later with vm auth set.'
        return false
      end
      hint = optional ? '; Return to skip' : ''
      key = console.getpass("OpenRouter API key (stored only on this host#{hint}): ").to_s.strip
      if key.empty?
        raise Error, 'No key entered; existing credentials were kept.' unless optional
        puts 'Skipped OpenRouter credentials. Add them later with vm auth set.'
        return false
      end
      store(key)
      true
    end
    def self.offer_pi
      puts 'Optional: keep an OpenRouter key on this Mac for Pi. Skip to configure any provider normally inside Pi.'
      if available?
        console = IO.console
        return false unless console
        console.print 'Use the existing host OpenRouter key for this VM? [y/N]: '
        return false unless %w[y yes].include?(console.gets.to_s.strip.downcase)
        true
      else
        prompt(optional:true)
      end
    end
  end

  class Credentials
    include ServiceModes
    def initialize(vm); @vm = vm; end
    def label; 'local.second-mac.' + @vm.name + '.model-relay'; end
    def state_path; @vm.file('model-relay.json'); end
    def grant_path; @vm.file('model-relay-grant.json'); end
    def session_path; @vm.file('model-relay-once.json'); end
    def record(path)
      File.file?(path) ? JSON.parse(File.read(path)) : {}
    rescue JSON::ParserError
      {}
    end
    def autostart?
      record(@vm.file('config.json')).fetch('credential_relays', []).include?('openrouter')
    end
    def save_autostart(value); @vm.config['credential_relays'] = value ? ['openrouter'] : []; end
    def enabled?; requested?; end
    def fingerprint
      Digest::SHA256.hexdigest(%w[core.rb credentials.rb service-modes.rb model-relay-api.rb ../guest/configure-relay.rb].map { |f| File.read(File.join(__dir__, f)) }.join)
    end
    def active?
      value = record(state_path)
      return false unless enabled? && HostCredentials.available? && value['owner'].to_i > 0 && value['owner'] == @vm.running_pid
      client = Net::HTTP.new('127.0.0.1', value.fetch('host_port'), nil)
      client.open_timeout = client.read_timeout = 2
      client.get('/health', 'Authorization'=>'Bearer ' + record(grant_path).fetch('token')).code == '200'
    rescue StandardError
      false
    end
    def lock
      File.open(@vm.file('model-relay.lock'), File::RDWR | File::CREAT, 0600) do |file|
        raise Error, 'Another host-credential change is in progress.' unless file.flock(File::LOCK_EX | File::LOCK_NB)
        yield
      end
    end
    def stop(revoke_session:true)
      File.unlink(state_path) if File.file?(state_path)
      clear_session if revoke_session
      system('/bin/launchctl', 'bootout', @vm.domain + '/' + label, out:File::NULL, err:File::NULL)
    end
    def client(value)
      script = File.read(File.expand_path('../guest/configure-relay.rb', __dir__))
      @vm.ssh('/usr/bin/ruby', '-e', script, input:JSON.generate(value), capture:true, timeout:20)
    end
    def configure_client
      grant = record(grant_path)
      client('enabled'=>true, 'provider'=>'openrouter', 'base_url'=>"http://127.0.0.1:#{grant.fetch('guest_port')}/v1", 'token'=>grant.fetch('token'))
    end
    def cleanup_client
      return unless @vm.config['credential_relay_cleanup'] && @vm.running?
      client('enabled'=>false)
      @vm.config['credential_relay_cleanup'] = false
      @vm.save
    end
    def start
      cleanup_client
      return unless enabled? && @vm.running?
      unless HostCredentials.available?
        stop(revoke_session:false) if File.file?(state_path)
        warn 'OpenRouter relay is inactive: no host key. Add it with vm auth set.'
        return
      end
      starting = false
      lock do
        if active? && record(state_path)['source'] == fingerprint
          configure_client # Idempotent; also covers Pi being installed later.
          return
        end
        starting = true
        stop(revoke_session:false)
        path = @vm.file('model-relay.plist')
        AgentVM.write(path, AgentVM.plist('Label'=>label, 'ProgramArguments'=>[
          '/usr/bin/ruby', File.join(__dir__, 'cli.rb'), '--name', @vm.name, 'auth', 'serve', @vm.running_pid.to_s],
          'EnvironmentVariables'=>{'AGENT_VM_HOME'=>AgentVM.state_root, 'TART_HOME'=>ENV.fetch('TART_HOME', File.join(Dir.home,'.tart')), 'LANG'=>'en_US.UTF-8', 'LC_ALL'=>'en_US.UTF-8'},
          'RunAtLoad'=>true, 'KeepAlive'=>{'SuccessfulExit'=>false}, 'ThrottleInterval'=>5, 'ExitTimeOut'=>3,
          'StandardOutPath'=>File::NULL, 'StandardErrorPath'=>@vm.file('model-relay.log')))
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        begin
          AgentVM.run('/bin/launchctl', 'bootstrap', @vm.domain, path, capture:true)
        rescue Error
          raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.2
          retry
        end
        @vm.wait_for(35, 'Starting OpenRouter host credentials') { active? }
      end
    rescue StandardError
      stop(revoke_session:false) if starting
      raise
    end
    def serve(owner)
      raise Error, 'Invalid VM process.' unless owner.match?(/\A[1-9]\d*\z/)
      owner = owner.to_i
      return unless enabled? && HostCredentials.available? && @vm.running_pid == owner
      grant = record(grant_path)
      grant = {'token'=>SecureRandom.hex(32)} if grant.empty?
      generation, active = SecureRandom.hex(16), true
      api = ModelRelayAPI.new(token:grant.fetch('token'), active:-> { active }, key:-> { HostCredentials.read })
      server = api.server
      port = server.listeners.first.addr[1]
      socket = @vm.control_socket('model-relay-' + generation)
      # A private-channel stream can remain open after a guest reboot. Probe
      # only this service's tunnel so launchd can reconnect it automatically.
      child = Process.detach(Process.spawn(*@vm.ssh_args, '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2', '-M', '-S', socket, '-NT', @vm.name,
        in:File::NULL, out:File::NULL, err:File::NULL))
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      until File.socket?(socket)
        raise Error, 'Model relay SSH channel did not start.' unless child.alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.1
      end
      remote = AgentVM.run(*@vm.ssh_args, '-S', socket, '-O', 'forward', '-o', 'ExitOnForwardFailure=yes',
        '-R', "127.0.0.1:#{grant.fetch('guest_port', 0)}:127.0.0.1:#{port}", @vm.name, capture:true, timeout:10).strip
      grant['guest_port'] ||= Integer(remote, 10)
      # Retain the port/token across normal stops, updates and memory resume, so
      # a running Pi process need not reload its cached connection settings.
      AgentVM.json_write(grant_path, grant) unless record(grant_path) == grant
      configure_client
      raise Error, 'Host credential access changed during startup.' unless enabled? && HostCredentials.available? && @vm.running_pid == owner
      AgentVM.json_write(state_path, {'owner'=>owner, 'generation'=>generation, 'source'=>fingerprint,
        'host_port'=>port, 'guest_port'=>grant.fetch('guest_port')})
      %w[TERM INT].each do |signal|
        trap(signal) { active = false; server.shutdown; Thread.new { api.close } }
      end
      retry_forward = false
      monitor = Thread.new do
        loop do
          sleep 0.5
          break unless enabled? && HostCredentials.available? && @vm.running_pid == owner && record(state_path)['generation'] == generation && child.alive?
        end
        retry_forward = enabled? && HostCredentials.available? && @vm.running_pid == owner && record(state_path)['generation'] == generation
        active = false
        api.close
        server.shutdown
      end
      server.start
      raise Error, 'Model relay channel disconnected; retrying while this VM is running.' if retry_forward
    ensure
      active = false
      monitor.kill if monitor
      api.close if api
      server.shutdown if server
      if child && child.alive?
        Process.kill('TERM', child.pid) rescue Errno::ESRCH
        unless child.join(2)
          Process.kill('KILL', child.pid) rescue Errno::ESRCH
          child.join
        end
      end
      File.unlink(socket) if socket && File.socket?(socket)
      File.unlink(state_path) if generation && record(state_path)['generation'] == generation
      clear_session(owner:owner) if owner.is_a?(Integer) && @vm.running_pid != owner
    end
    def set(mode, once:false)
      lock do
        HostCredentials.read if mode == 'on'
        select_mode(mode == 'on', once:once)
        if mode == 'off'
          @vm.config['credential_relay_cleanup'] = true
          @vm.save
          stop(revoke_session:false)
          File.unlink(grant_path) if File.file?(grant_path)
        end
      end
      mode == 'on' ? start : cleanup_client
    end
    def status
      state = if !HostCredentials.available? then 'inactive; add a host key with vm auth set'
              elsif !enabled? then 'off'
              elsif active? then 'active'
              elsif @vm.running? then 'enabled but unavailable; run vm auth relay on to retry'
              else 'enabled; inactive until VM starts'
              end
      puts 'OpenRouter host credentials: ' + state
      puts "OpenRouter autostart: #{autostart? ? 'on' : 'off'} (requires a host key)."
      puts 'Host key file: ' + HostCredentials.path
      puts 'Guest receives a local relay credential only. Access stops with this VM; throwaways start with access off.'
    end
    def guest_auth
      raise Error, 'Install Pi first: vm agents add pi' unless @vm.config['agents'].include?('pi')
      @vm.start unless @vm.running?
      exec(*@vm.ssh_args, '-t', @vm.name, Shellwords.join(['nano', @vm.home + '/.pi/agent/auth.json']))
    end
    def import_guest_key
      raise Error, 'Host relay is already enabled; edit its key with vm auth host.' if enabled?
      @vm.start unless @vm.running?
      value = @vm.ssh('/usr/bin/ruby', '-rjson', '-e', <<~'GUEST', capture:true, timeout:20)
        entry = JSON.parse(File.read(File.join(Dir.home, '.pi/agent/auth.json')))['openrouter']
        abort 'Pi has no saved OpenRouter API key.' unless entry && entry['type'] == 'api_key' && entry['key'].is_a?(String) && !entry['key'].empty?
        print JSON.generate(entry['key'])
      GUEST
      key = JSON.parse(value)
      raise Error, 'Pi uses a key command; put the resolved key in vm auth host instead.' if key.start_with?('!') || key.match?(/\s/)
      raise Error, 'A different host key already exists; choose it with vm auth relay on, or edit vm auth host.' if HostCredentials.available? && HostCredentials.read != key
      HostCredentials.prepare
      AgentVM.write(HostCredentials.path, key + "\n")
      set('on')
      puts 'Moved the saved Pi key to the host and replaced its current guest entry with the relay credential.'
      puts 'Old snapshots or other copies may still contain the previous key; rotate it if that matters.'
    end
    def command(args)
      action = args.shift || (enabled? ? 'host' : 'guest')
      case action
      when 'set'
        raise Error, 'Usage: vm auth set (the key is entered privately, never as an argument)' unless args.empty?
        HostCredentials.prompt(replace:true)
        set('on')
        status
      when 'host'
        raise Error, 'Usage: vm auth host [--path | --from-guest]' unless [[], ['--path'], ['--from-guest']].include?(args)
        return puts(HostCredentials.path) if args == ['--path']
        return import_guest_key if args == ['--from-guest']
        HostCredentials.prepare
        editor = Shellwords.split(ENV['VISUAL'] || ENV['EDITOR'] || '/usr/bin/nano')
        AgentVM.run(*editor, HostCredentials.path)
        HostCredentials.prepare
        start if enabled? && @vm.running?
      when 'guest'
        raise Error, 'Usage: vm auth guest' unless args.empty?
        guest_auth
      when 'relay'
        mode = args.shift || 'status'
        if mode == 'autostart'
          value = args.shift || 'status'
          raise Error, 'Usage: vm auth relay autostart on|off|status' unless args.empty? && %w[on off status].include?(value)
          set_autostart(value == 'on') unless value == 'status'
          return puts "OpenRouter autostart: #{autostart? ? 'on' : 'off'} (requires a host key). Current-run access is unchanged."
        end
        once = %w[on off].include?(mode) && args == ['--once']
        raise Error, 'Usage: vm auth relay on|off [--once] | status | autostart on|off|status' unless %w[on off status].include?(mode) && (args.empty? || once)
        set(mode, once:once) unless mode == 'status'
        status
      when 'serve'
        raise Error, 'Expected one VM process.' unless args.length == 1
        serve(args.first)
      else
        raise Error, 'Usage: vm auth [set | host [--path | --from-guest] | guest | relay on|off [--once] | relay status | relay autostart on|off]'
      end
    end
  end
end
