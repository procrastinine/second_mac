require_relative 'core'
require_relative 'network-build'
require 'socket'
require 'tmpdir'

module AgentVM
  # Native Softnet stays on the normal data path. The optional userspace router
  # uses ordinary host sockets, which work with VPNs that reject vmnet traffic.
  class Network
    PATH = '/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'.freeze
    def initialize(vm); @vm = vm; end
    def state
      JSON.parse(File.read(@vm.file('network-state.json')))
    rescue Errno::ENOENT, JSON::ParserError
      {}
    end
    def self.tunnel_route?(text)
      text.match?(/^\s*interface: (?:utun|tun|ppp|ipsec)\d*\s*$/)
    end
    def desired
      mode = @vm.config.fetch('network_mode', 'auto')
      return mode unless mode == 'auto'
      route = AgentVM.run('/sbin/route', '-n', 'get', '1.1.1.1', capture:true, timeout:5)
      self.class.tunnel_route?(route) ? 'vpn' : 'native'
    rescue Error
      # If routing cannot be inspected, use host sockets rather than risk
      # choosing vmnet outside an unknown tunnel configuration.
      'vpn'
    end
    def build
      NetworkBuild.new(@vm).install
    end
    def prepare
      backend = desired
      value = {'backend'=>backend}
      value['binary'] = helper(backend) unless backend == 'native'
      if backend == 'vpn' && %w[creating bootstrap].include?(@vm.config['phase'])
        socket = TCPServer.new('127.0.0.1', 0)
        value['bootstrap_port'] = socket.addr[1]
        socket.close
      end
      AgentVM.json_write(@vm.file('network-state.json'), value)
      puts "Network: #{backend == 'off' ? 'off (SSH and explicit forwards remain available)' : (backend == 'vpn' ? 'VPN-compatible host sockets' : 'native Softnet (host and LAN blocked)')}."
    end
    def helper(backend)
      return File.join(__dir__, 'network-offline.rb') if backend == 'off'
      backend == 'vpn' ? build : '/opt/homebrew/bin/softnet'
    end
    # The existing supervisor accepts alternative helpers in its vpn slot.
    # Reuse that protocol so even an already-running older supervisor can go
    # offline without replacing Tart or disrupting its VirtIO SSH session.
    def wire_backend(backend); backend == 'off' ? 'vpn' : backend; end
    def environment
      value = state
      result = {'PATH'=>File.join(__dir__, 'network-bin') + ':' + PATH,
                'SECOND_MAC_NETWORK_SOCKET'=>@vm.control_socket('network'),
                'SECOND_MAC_NETWORK_BACKEND'=>wire_backend(value.fetch('backend', 'native'))}
      return result unless %w[vpn off].include?(value['backend'])
      binary = value.fetch('binary')
      raise Error, 'VPN network helper is missing; run vm start to rebuild it.' unless File.executable?(binary)
      result['SECOND_MAC_NETWORK_BINARY'] = binary
      if %w[creating bootstrap].include?(@vm.config['phase']) && value['bootstrap_port']
        result['SECOND_MAC_BOOTSTRAP_PORT'] = value['bootstrap_port'].to_s
      end
      result
    end
    def bootstrap_endpoint
      value = state
      return ['127.0.0.1', value.fetch('bootstrap_port')] if value['backend'] == 'vpn'
      [AgentVM.run(@vm.tart, 'ip', @vm.name, capture:true, timeout:10).strip, 22]
    end
    def configure_dns(renew:false)
      return if state['backend'] == 'off'
      source = File.expand_path('../guest/network-dns.rb', __dir__)
      @vm.root('/usr/bin/ruby', '-e', File.read(source), state.fetch('backend', 'native'), renew ? 'renew' : 'keep', timeout:45)
    end
    def summary
      backend = @vm.running? ? state.fetch('backend', 'native') : desired
      label = backend == 'off' ? 'Off (SSH and explicit forwards kept)' : (backend == 'vpn' ? 'VPN-compatible' : 'Native Softnet')
      "#{label}; selection #{@vm.config.fetch('network_mode', 'auto')}"
    end
    def observed_status
      value = request('op'=>'network-status')
      saved = state
      if value['backend'] == 'vpn' && (value['binary'] == helper('off') || (saved['backend'] == 'off' && saved['owner'] == value['pid']))
        value = value.merge('backend'=>'off')
      end
      value
    end
    def request(value)
      socket = nil
      path = @vm.control_socket('network')
      raise Error, 'Live networking activates on the next VM start. Existing sessions are unchanged.' unless File.socket?(path)
      metadata = File.lstat(path)
      raise Error, 'Unsafe network control socket.' unless metadata.uid == Process.uid && (metadata.mode & 0077).zero?
      Timeout.timeout(20) do
        socket = UNIXSocket.new(path)
        raise Error, 'Unexpected network controller owner.' unless socket.getpeereid.first == Process.uid
        socket.write(JSON.generate(value) + "\n")
        line = socket.gets(65537)
        raise Error, 'Invalid network controller response.' unless line && line.end_with?("\n") && line.bytesize <= 65536
        result = JSON.parse(line)
        raise Error, result['error'] if result['error']
        result
      end
    rescue Timeout::Error, JSON::ParserError, SystemCallError => error
      raise Error, "Network controller unavailable (#{error.class}); the VM remains running."
    ensure
      socket.close if socket && !socket.closed?
    end
    def refresh(force:true)
      result = nil
      @vm.with_lifecycle_lock do
        return unless @vm.running?
        status = request('op'=>'network-status')
        unless status['live_switch'] && status['pid'] == @vm.running_pid
          raise Error, 'This VM predates live network switching. Run vm update, then restart once; later network changes are live.'
        end
        backend = desired
        saved = state
        # Recheck connected addresses even if the route still selects the same
        # backend. A new LAN can use public IPv4 space outside PRIVATE_NETS.
        # Older running supervisors report their last applied rules in state.
        blocks = AgentVM.blocked_networks(AgentVM.run('/sbin/ifconfig', capture:true, timeout:5)).uniq.sort.join(',')
        active_blocks = status['blocks'] || (saved['blocks'] if saved['owner'] == status['pid'])
        policy_changed = active_blocks.to_s.split(',').sort.join(',') != blocks
        backend_changed = status['backend'] != wire_backend(backend) || saved['backend'] != backend
        if force || backend_changed || policy_changed || status['healthy'] == false
          binary = helper(backend)
          result = request('op'=>'network-set', 'backend'=>wire_backend(backend), 'binary'=>binary, 'blocks'=>blocks)
          raise Error, 'VM changed during its network switch.' unless result['pid'] == @vm.running_pid
          AgentVM.json_write(@vm.file('network-state.json'), {'backend'=>backend, 'binary'=>binary, 'owner'=>result['pid'], 'blocks'=>blocks})
          # A filter refresh does not change guest addressing or DNS. Avoid
          # needless DHCP/guest work on a same-backend LAN change.
          configure_dns(renew:true) if force || backend_changed || saved['dns_pending'] || status['healthy'] == false
        elsif saved['dns_pending']
          configure_dns(renew:true)
          AgentVM.json_write(@vm.file('network-state.json'), state.reject { |key, _| key == 'dns_pending' })
        end
      end
    rescue Error
      # A successful helper switch can precede a temporarily busy guest.
      # Retain its actual backend and retry DHCP/DNS without replacing it again.
      AgentVM.json_write(@vm.file('network-state.json'), state.merge('dns_pending'=>true)) if result
      raise
    end
    def watcher_label; 'local.second-mac.' + @vm.name + '.network'; end
    def stop_watcher
      system('/bin/launchctl', 'bootout', @vm.domain + '/' + watcher_label, out:File::NULL, err:File::NULL)
    end
    def start_watcher
      return unless @vm.running?
      owner = @vm.running_pid
      saved = JSON.parse(File.read(@vm.file('network-watcher.json'))) rescue {}
      if saved['owner'] == owner
        job, status = Open3.capture2e('/bin/launchctl', 'print', @vm.domain + '/' + watcher_label)
        return if status.success? && job.match?(/^\s*pid = \d+$/)
      end
      stop_watcher
      path = @vm.file('network-watcher.plist')
      AgentVM.write(path, AgentVM.plist('Label'=>watcher_label, 'ProgramArguments'=>[
        '/usr/bin/ruby', File.join(__dir__, 'network-watch.rb'), @vm.name, owner.to_s],
        'EnvironmentVariables'=>{'AGENT_VM_HOME'=>AgentVM.state_root, 'TART_HOME'=>ENV.fetch('TART_HOME', File.join(Dir.home, '.tart'))},
        'RunAtLoad'=>true, 'KeepAlive'=>false, 'ExitTimeOut'=>3,
        'StandardOutPath'=>File::NULL, 'StandardErrorPath'=>@vm.file('network.log')))
      AgentVM.run('/bin/launchctl', 'bootstrap', @vm.domain, path, capture:true)
      AgentVM.json_write(@vm.file('network-watcher.json'), {'owner'=>owner})
    end
    def watch(owner)
      previous_error = nil
      loop do
        break unless @vm.running_pid == owner
        @vm = VM.load(@vm.name) # Each VM, including a throwaway, owns its policy.
        begin
          refresh(force:false)
          previous_error = nil
        rescue Error => e
          warn e.message unless previous_error == e.message
          previous_error = e.message
        end
        sleep 3
      end
    end
    def command(args)
      mode = args.shift || 'status'
      unless %w[status auto native vpn off on refresh].include?(mode) && args.empty?
        raise Error, 'Usage: vm network status|auto|native|vpn|off|on|refresh (live; SSH and forwards are kept)'
      end
      return puts(summary) if mode == 'status'
      was_running = @vm.running?
      old = @vm.config.fetch('network_mode', 'auto')
      previous_resume = @vm.config['network_resume_mode']
      @vm.config['network_resume_mode'] = old if mode == 'off' && old != 'off'
      mode = @vm.config.fetch('network_resume_mode', 'auto') if mode == 'on'
      @vm.config['network_mode'] = mode unless mode == 'refresh'
      build if was_running && desired == 'vpn'
      refresh(force:mode == 'refresh') if was_running
      @vm.save
      start_watcher if was_running
      puts summary
    rescue Error
      @vm.config['network_mode'] = old if old
      @vm.config['network_resume_mode'] = previous_resume if defined?(previous_resume)
      raise
    end
  end
end
