require_relative 'core'

module AgentVM
  class Audio
    def initialize(vm); @vm = vm; end

    def attached
      return false unless @vm.running?
      receipt = JSON.parse(File.read(@vm.file('access-launch.json')))
      receipt['audio_output'] if receipt['pid'] == @vm.running_pid
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    def muted?
      return nil unless @vm.running?
      value = @vm.rpc('/usr/bin/osascript', '-e', 'output muted of (get volume settings)', capture:true, timeout:2).strip
      {'true'=>true, 'false'=>false}[value]
    rescue Error
      nil
    end

    def command(argv)
      args = argv.dup
      mode = args.shift || 'status'
      if %w[help --help -h].include?(mode) && args.empty?
        puts 'vm audio on|off [--restart] — configure output to host speakers/headphones independently of microphone input.'
        puts 'A running VM keeps its attached devices until its next start, unless --restart is explicit.'
        puts 'vm audio mute|unmute — change guest playback immediately, without restarting. This is a guest volume setting, not device removal.'
        puts 'vm audio status — show configured/attached output and guest volume. Host microphone remains separately opt-in.'
        return
      end
      raise Error, 'Usage: vm audio on|off [--restart] | mute | unmute | status' unless
        (%w[on off].include?(mode) && [[], ['--restart']].include?(args)) || (%w[mute unmute status].include?(mode) && args.empty?)
      if mode == 'status'
        active = attached
        puts "Audio output: configured #{@vm.config['audio_output'] ? 'on' : 'off'}; attached #{active.nil? ? 'unknown until next managed start' : (active ? 'on' : 'off')}"
        puts "Host microphone: #{@vm.config['microphone'] ? 'configured on' : 'configured off'} (independent)"
        puts @vm.rpc('/usr/bin/osascript', '-e', 'get volume settings', capture:true, timeout:5) if @vm.running?
      elsif %w[mute unmute].include?(mode)
        raise Error, 'The VM is stopped; there is no live playback to change.' unless @vm.running?
        raise Error, 'Output is not attached. Enable vm audio on for the next start, or explicitly use vm audio on --restart.' if mode == 'unmute' && attached == false
        @vm.rpc('/usr/bin/osascript', '-e', "set volume output muted #{mode == 'mute' ? 'true' : 'false'}", capture:true, timeout:5)
        puts "Guest playback #{mode == 'mute' ? 'muted' : 'unmuted'}; VM sessions kept."
      else
        if @vm.config['runtime_mode'] == 'standard'
          raise Error, 'Independent audio requires custom Tart: vm runtime custom. Existing playback can still use vm audio mute/unmute.'
        end
        @vm.with_lifecycle_lock do
          desired = mode == 'on'
          changed = @vm.config['audio_output'] != desired
          @vm.config['audio_output'] = desired
          @vm.save if changed
        end
        running = @vm.running?
        if running && args == ['--restart'] && attached != @vm.config['audio_output']
          @vm.stop
          @vm.start
          puts "Audio output #{mode}; microphone setting kept."
        elsif running && attached != @vm.config['audio_output']
          puts "Audio output #{mode} saved for the next start; current sessions kept. Use vm audio mute to silence current playback immediately."
        else
          puts "Audio output #{mode}#{running ? '' : ' for the next start'}; microphone setting kept."
        end
      end
    end
  end
end
