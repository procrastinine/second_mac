require_relative 'core'

module AgentVM
  class Microphone
    def initialize(vm); @vm = vm; end
    def attached
      return false unless @vm.running?
      data = JSON.parse(File.read(@vm.file('access-launch.json')))
      data['microphone'] if data['pid'] == @vm.running_pid
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end
    def command(args)
      mode = args.shift || 'status'
      unless %w[status on off help --help -h].include?(mode) && [[], ['--restart']].include?(args)
        raise Error, 'Usage: vm microphone on|off [--restart] | status | help'
      end
      if %w[help --help -h].include?(mode)
        puts 'vm microphone on|off [--restart] — opt into host default microphone input. Playback is separate: vm audio.'
        puts 'Default: off. Device changes apply at the next cold start; --restart immediately restarts Tart and guest macOS.'
        puts 'Approve any host microphone prompt yourself. Guest-control cannot enable host microphone sharing.'
        return
      end
      if mode == 'status'
        active = attached
        puts "Host microphone: configured #{@vm.config['microphone'] ? 'on' : 'off'}; attached #{active.nil? ? 'unknown' : (active ? 'on' : 'off')}."
        puts 'Playback: vm audio status. Regular Tart couples input and output; custom Tart separates them.'
        return
      end
      enabled = mode == 'on'
      was_running = @vm.running?
      changed = @vm.config['microphone'] != enabled
      apply_now = was_running && args == ['--restart'] && attached != enabled
      return puts('Microphone setting is already ' + mode + '.') unless changed || apply_now
      @vm.stop if apply_now
      @vm.config['microphone'] = enabled
      @vm.save if changed
      @vm.start if apply_now
      puts "Microphone sharing #{enabled ? 'enabled' : 'disabled'}#{apply_now ? '' : ' for the next cold start'}."
      puts 'The currently attached microphone is unchanged; --restart applies the device change immediately and ends guest sessions.' if was_running && !apply_now
      if enabled
        puts 'Any host microphone consent remains user-controlled.'
        puts(@vm.config['runtime_mode'] == 'standard' ? 'Regular Tart couples playback with microphone input.' : 'Playback is unchanged.')
      end
    end
  end
end
