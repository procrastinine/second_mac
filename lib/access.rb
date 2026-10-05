require_relative 'core'
require_relative 'ports'
require_relative 'network'
require_relative 'ui'
require_relative 'guest-control'
require_relative 'camera'
require_relative 'permissions'
require_relative 'credentials'

module AgentVM
  # Inspect managed access without booting, capturing media, granting access,
  # probing the internet or changing a retained copy's saved implementation.
  class Access
    def initialize(vm)
      @vm = vm
    end

    def observe(label)
      yield
    rescue Error, SystemCallError, IOError, JSON::ParserError, Timeout::Error
      @unavailable << label
      nil
    end

    def launch_receipt(pid)
      path = @vm.file('access-launch.json')
      return nil unless File.file?(path)
      data = JSON.parse(File.read(path))
      data if data['pid'] == pid
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def share_rows(entries)
      entries.map do |entry|
        { 'host'=>entry.fetch('host'), 'guest'=>"/Volumes/#{entry.fetch('name')}",
          'tag'=>entry.fetch('tag'), 'kind'=>entry.fetch('kind'), 'read_only'=>entry.fetch('read_only') }
      end
    end

    def report
      @unavailable = []
      pid = @vm.running_pid
      running = pid > 0
      receipt = running ? launch_receipt(pid) : nil
      configured = share_rows(AgentVM.share_entries(@vm.config))
      attached = running ? (receipt && share_rows(receipt.fetch('shares'))) : []
      @unavailable << 'launch attachments (recorded on the next managed start)' if running && !receipt
      mounts = running ? observe('guest mount status') { @vm.rpc('/sbin/mount', capture:true, timeout:5) } : ''
      mounted = mounts && mounts.lines.select { |line| line.match?(/\((AppleVirtIOFS|virtiofs)[,) ]/) }.map do |line|
        path = line[/ on (.+) \(/, 1]
        { 'guest'=>path, 'read_only'=>line.match?(/\bread-only\b/) }
      end
      network = running ? observe('network controller') { Network.new(@vm).observed_status } : nil
      if network && network['pid'] != pid
        network = nil
        @unavailable << 'network controller (process mismatch)'
      end
      ports = Ports.new(@vm)
      forwards = ports.entries.map do |entry|
        host_service = entry.fetch('direction') == 'host'
        { 'service'=>"#{host_service ? 'host' : 'guest'} 127.0.0.1:#{entry.fetch('from')}",
          'listener'=>"#{host_service ? 'guest' : 'host'} 127.0.0.1:#{entry.fetch('to')}",
          'active'=>running ? observe('port forward status') { ports.alive?(entry) } : false }
      end
      ui = running ? observe('guest UI controller') do
        if File.socket?(File.join(@vm.tart_directory, 'ui.sock'))
          @vm.ui_available? && Desktop.new(@vm).request({'op'=>'status'}, timeout:3)['pid'] == pid
        else
          false
        end
      end : false
      control = GuestControl.new(@vm)
      delegation = running ? observe('guest delegation') { control.active? } : false
      camera = running ? observe('OBS camera bridge') { Camera.new(@vm).active? } : false
      auto_approval = running ? observe('permission approval service') do
        job, status = Open3.capture2e('/bin/launchctl', 'print', @vm.domain+'/'+Permissions.new(@vm).label)
        status.success? && job.match?(/^\s*pid = [1-9]\d*$/)
      end : false
      devices = %w[audio_output microphone clipboard usb].to_h do |key|
        [key, {'configured'=>%w[audio_output microphone].include?(key) && @vm.config[key],
               'attached'=>running ? (receipt && receipt[key]) : false}]
      end
      devices['obs_camera'] = {'configured'=>@vm.config['camera_obs'], 'active'=>camera}
      result = {
        'vm'=>@vm.name, 'state'=>running ? 'running' : (@vm.suspended? ? 'suspended' : 'stopped'),
        'throwaway_id'=>@vm.config.dig('throwaway', 'id'),
        'shares'=>{'configured'=>configured, 'attached'=>attached, 'mounted'=>mounted},
        'network'=>{'selection'=>@vm.config.fetch('network_mode', 'auto'),
          'policy'=>(@vm.config['network_mode'] == 'off' ? 'Ethernet disconnected; private SSH and explicit TCP forwards remain available.' : 'Host and LAN blocked; explicit TCP forwards only. Public internet allowed.'),
          'active_backend'=>network && network['backend'],
          'healthy'=>running ? (network && network['healthy']) : false},
        'ports'=>forwards, 'devices'=>devices,
        'host_credentials'=>{'openrouter'=>{'enabled'=>Credentials.new(@vm).enabled?,
          'autostart'=>Credentials.new(@vm).autostart?, 'key_present'=>HostCredentials.available?,
          'active'=>running ? observe('OpenRouter relay') { Credentials.new(@vm).active? } : false}},
        'control'=>{
          'host_ui'=>{'configured'=>@vm.config['ui_enabled'], 'active'=>ui},
          'guest_delegation'=>{'autostart'=>@vm.config['guest_control'],
            'enabled_now'=>running ? control.enabled? : false, 'active'=>delegation,
            'scope'=>'Guest UI and app permissions only; no host files, ports, media, SIP or lifecycle changes.'},
          'automatic_permission_approval'=>{'configured'=>@vm.config['permissions_auto'] == true, 'active'=>auto_approval}
        },
        'unavailable'=>@unavailable.uniq
      }
      raise Error, 'The VM changed power state during inspection; rerun vm access.' unless @vm.running_pid == pid
      result
    end

    def state(value)
      value.nil? ? 'unknown' : (value ? 'on' : 'off')
    end

    def folder(row)
      "#{row['host']} -> #{row['guest']} (#{row['read_only'] ? 'read-only' : 'read/write'}, #{row['kind'] == 'macfuse' ? 'scoped links over VirtioFS' : 'native VirtioFS'})"
    end

    def render(data)
      lines = ["#{data['vm']}: #{data['state']}#{data['throwaway_id'] ? ' · throwaway ' + data['throwaway_id'] : ''}",
        'Configured host folders:']
      shares = data.fetch('shares')
      lines << '  None' if shares['configured'].empty?
      shares['configured'].each { |row| lines << '  ' + folder(row) }
      lines << 'Attached to this boot:'
      if shares['attached'].nil?
        lines << '  Unknown (no matching launch receipt)'
      elsif shares['attached'].empty?
        lines << '  None'
      else
        shares['attached'].each do |row|
          mount = shares['mounted'] && shares['mounted'].find { |m| m['guest'] == row['guest'] }
          observed = shares['mounted'].nil? ? 'mount unknown' : (mount ? "mounted #{mount['read_only'] ? 'read-only' : 'read/write'}" : 'not mounted')
          lines << "  #{folder(row)}; #{observed}"
        end
      end
      net = data.fetch('network')
      lines << "Network policy: #{net['policy']}"
      active = data['state'] != 'running' ? 'off' : (net['active_backend'] || 'unknown')
      lines << "  Selection: #{net['selection']}; active backend: #{active}; healthy: #{state(net['healthy'])}"
      lines << 'TCP forwards (listener -> service):'
      lines << '  None' if data['ports'].empty?
      data['ports'].each { |port| lines << "  #{port['listener']} -> #{port['service']}; controller #{state(port['active'])}" }
      data['host_credentials'].each { |name, value| lines << "Host credential relay: #{name}; enabled #{state(value['enabled'])}; autostart #{state(value['autostart'])}; host key #{state(value['key_present'])}; active #{state(value['active'])}" }
      lines << 'Host devices:'
      data['devices'].each { |key, value| lines << "  #{key.tr('_', ' ')}: configured #{state(value['configured'])}; #{value.key?('attached') ? 'attached' : 'active'} #{state(value.fetch('attached', value['active']))}" }
      lines << 'Guest UI and permissions:'
      data['control'].each do |key, value|
        desired = value.key?('autostart') ? "autostart #{state(value['autostart'])}, enabled now #{state(value['enabled_now'])}" : "configured #{state(value['configured'])}"
        lines << "  #{key.tr('_', ' ')}: #{desired}; active #{state(value['active'])}"
      end
      lines << '  ' + data['control']['guest_delegation']['scope']
      lines << 'Unavailable: ' + data['unavailable'].join('; ') unless data['unavailable'].empty?
      lines << 'Read-only snapshot of managed access; this does not probe firewall rules or service contents.'
      lines.join("\n")
    end

    def command(args)
      raise Error, 'Usage: vm access [--json]' unless [[], ['--json']].include?(args)
      data = report
      puts(args == ['--json'] ? JSON.pretty_generate(data) : render(data))
    end
  end
end
