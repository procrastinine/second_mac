require_relative 'core'
require_relative 'ui-build'
require 'socket'

module AgentVM
  class Runtime
    MODES = %w[auto standard custom].freeze
    def initialize(vm); @vm = vm; end
    def selected; @vm.needs_custom_tart? ? 'custom' : 'standard'; end
    def request(value, timeout:10)
      socket = nil
      raise Error, 'The VM is stopped.' unless @vm.running?
      path = File.join(@vm.tart_directory, 'runtime.sock')
      raise Error, 'This running Tart has no live runtime controller. Select custom Tart for the next start.' unless File.socket?(path)
      st = File.lstat(path)
      raise Error, 'Unsafe runtime socket.' unless st.uid == Process.uid && (st.mode & 0077).zero?
      Timeout.timeout(timeout) do
        socket = Dir.chdir(@vm.tart_directory) { UNIXSocket.new('runtime.sock') }
        raise Error, 'Unexpected runtime owner.' unless socket.getpeereid.first == Process.uid
        socket.write(JSON.generate(value) + "\n")
        line = socket.gets(262145)
        raise Error, 'Invalid runtime response.' unless line && line.end_with?("\n") && line.bytesize <= 262144
        result = JSON.parse(line)
        raise Error, result['error'] if result['error']
        raise Error, 'The VM changed during the runtime request.' unless result['pid'] == @vm.running_pid
        result
      end
    rescue Timeout::Error, JSON::ParserError, SystemCallError => e
      raise Error, "Runtime controller unavailable (#{e.class}); the VM was not forcibly stopped."
    ensure
      socket.close if socket && !socket.closed?
    end
    def current
      return nil unless @vm.running?
      return request('op'=>'status') if File.socket?(File.join(@vm.tart_directory, 'runtime.sock'))
      pid = @vm.running_pid
      receipt = JSON.parse(File.read(@vm.file('access-launch.json'))) rescue {}
      return receipt.merge('features'=>[], 'legacy'=>true) if receipt['pid'] == pid
      legacy = JSON.parse(File.read(@vm.file('ui-process.json'))) rescue {}
      if legacy['pid'] == pid
        {'pid'=>pid, 'runtime'=>'custom', 'features'=>[], 'ui_enabled'=>@vm.ui_available?, 'legacy'=>true}
      else
        {'pid'=>pid, 'runtime'=>'standard', 'features'=>[], 'legacy'=>true}
      end
    end
    def report
      active = current
      features = {
        'network_switching'=>'live, including off/on; standard and custom',
        'ssh_and_port_forwards'=>'live; standard and custom',
        'audio_volume'=>'live when playback is attached; standard and custom',
        'native_desktop'=>'custom can attach a viewer live; standard needs its window prepared at start',
        'guest_ui_control'=>active ? (active['ui_enabled'] ? 'available' : 'not enabled in this boot') : (@vm.configured_ui? ? 'enabled at next start' : 'not enabled'),
        'independent_audio'=>active ? (active.fetch('features', []).include?('independent-audio') ? 'available; device changes take effect at next start' : 'unavailable in this boot') : (selected == 'custom' ? 'available at next start' : 'requires custom Tart'),
        'live_shares'=>active ? (active.fetch('features', []).include?('live-shares') ? 'available' : 'unavailable in this boot') : (selected == 'custom' ? 'available at next start' : 'requires custom Tart'),
        'ui_enable_disable'=>active && active.fetch('features', []).include?('live-ui') ? 'live; guest boot and Tart process kept' : 'requires current custom Tart for live changes',
        'memory_resume'=>active ? ((active.fetch('features', []).include?('save-restore') || (active['suspendable'] && active['stable_devices'])) ? 'available; Tart restarts, guest boot and processes kept' : 'requires a new managed start') : (@vm.suspended? ? 'saved; original runtime will be used to resume' : 'available on a compatible managed start')
      }
      receipt = JSON.parse(File.read(@vm.file('access-launch.json'))) rescue {}
      active_release = receipt.dig('configuration', 'tart_version') if active && receipt['pid'] == @vm.running_pid
      {'selection'=>@vm.config.fetch('runtime_mode', 'auto'), 'next_start'=>selected,
        'active'=>active && active['runtime'], 'suspended'=>@vm.suspended?, 'legacy'=>active && active['legacy'] == true,
        'tart_release'=>@vm.config['tart_version'], 'active_release'=>active_release, 'features'=>features}
    end
    def choose(mode, restart:false, build:true)
      raise Error, 'Runtime must be auto, standard or custom.' unless MODES.include?(mode)
      raise Error, 'A retained throwaway keeps its saved runtime; select the source runtime before creating a new copy.' if @vm.config['throwaway']
      candidate = VM.new(@vm.config.merge('runtime_mode'=>mode))
      if build && candidate.needs_custom_tart?
        candidate.config['ui_tart'] = UIBuild.new(candidate).install
      end
      @vm.with_lifecycle_lock do
        @vm.config.replace(candidate.config)
        @vm.save
      end
      if restart && @vm.running?
        active = current
        used = JSON.parse(File.read(@vm.file('ui-process.json'))) rescue {}
        different = active['runtime'] != selected || (selected == 'custom' && used['binary'] != @vm.config['ui_tart'])
        if different
          @vm.stop
          @vm.start
        end
      end
      puts "Runtime selection: #{mode} (#{selected} at next start). Existing sessions keep their current executable."
      if mode == 'standard'
        puts 'Guest UI/OCR and independent audio preferences are retained but unavailable in standard Tart. Native GUI, network, SSH, forwards and file sharing remain available.'
      end
    end
    def command(argv)
      args = argv.dup
      action = args.shift || 'status'
      if action == '--json' && args.empty?
        action, args = 'status', ['--json']
      end
      if action == 'status'
        raise Error, 'Usage: vm runtime [status] [--json]' unless [[], ['--json']].include?(args)
        value = report
        return puts JSON.pretty_generate(value) if args == ['--json']
        puts "Tart #{value['tart_release']}: selection #{value['selection']}; next cold start #{value['next_start']}; running #{value['active'] || 'none'}#{value['active_release'] ? ' ' + value['active_release'] : ''}"
        value['features'].each { |name, availability| puts "  #{name.tr('_', ' ')}: #{availability}" }
        puts 'Older custom process: new patch features activate on its next start.' if value['legacy'] && value['active'] == 'custom'
      elsif MODES.include?(action)
        raise Error, 'Usage: vm runtime auto|standard|custom [--restart]' unless [[], ['--restart']].include?(args)
        choose(action, restart:args == ['--restart'])
      else
        raise Error, 'Usage: vm runtime [status [--json] | auto|standard|custom [--restart]]'
      end
    end
  end
end
