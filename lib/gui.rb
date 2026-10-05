require_relative 'core'

module AgentVM
  class GUI
    def initialize(vm)
      @vm = vm
    end
    def active?
      return true if @vm.running? && @vm.display_available?
      pid = @vm.running_pid
      pid > 0 && File.file?(@vm.file('gui-process.json')) &&
        JSON.parse(File.read(@vm.file('gui-process.json')))['pid'] == pid
    rescue JSON::ParserError, Errno::ENOENT
      false
    end
    def hidden?
      if @vm.display_available? && active?
        require_relative 'ui'
        return !Desktop.new(@vm).request({'op'=>'status'}, timeout:3)['gui_visible']
      end
      binary = @vm.file('gui-native')
      return false unless active? && File.executable?(binary)
      AgentVM.run(binary, @vm.running_pid.to_s, 'status', capture:true, timeout:3).strip == 'hidden'
    rescue Error
      false
    end
    def helper
      source = File.join(__dir__, 'gui.swift')
      digest = Digest::SHA256.file(source).hexdigest
      binary = @vm.file('gui-native')
      unless File.executable?(binary) && File.file?(@vm.file('gui-native.sha256')) && File.read(@vm.file('gui-native.sha256')) == digest
        AgentVM.run('/usr/bin/xcrun', 'swiftc', '-O', '-module-cache-path', @vm.file('swift-module-cache'), source, '-o', binary, timeout:120)
        AgentVM.write(@vm.file('gui-native.sha256'), digest)
      end
      binary
    end
    def command(args)
      unless [[], ['--restart'], ['--hide'], ['--headless']].include?(args)
        raise Error, 'Usage: vm gui [--restart | --hide | --headless]'
      end
      return puts('No desktop is visible; the VM remains stopped or suspended.') if args == ['--hide'] && !@vm.running?
      @vm.start if @vm.suspended? && !@vm.running?
      # Custom starts use their detachable viewer, including when automation is
      # off. Do not fall back to a stock window that cannot release its view.
      @vm.start(graphics:args != ['--headless']) if !@vm.running? && @vm.needs_custom_tart?
      if @vm.running? && !active?
        require_relative 'runtime'
        controller = Runtime.new(@vm)
        current = controller.current
        if current && current.fetch('features', []).include?('live-ui')
          controller.request('op'=>'ui-set', 'enabled'=>@vm.ui_available?)
        end
      end
      if @vm.display_available?
        require_relative 'ui'
        @vm.start unless @vm.running?
        Desktop.new(@vm).request({'op'=>args.any? { |a| %w[--hide --headless].include?(a) } ? 'hide' : 'show'}, timeout:5)
        puts 'Guest desktop visibility updated; the VM keeps running.'
        return
      end
      if args == ['--headless']
        if active?
          AgentVM.run(helper, @vm.running_pid.to_s, 'hide')
        else
          @vm.start(graphics:false) unless @vm.running?
        end
        puts 'VM runs without a visible window; existing sessions are preserved.'
        return
      end
      if args == ['--hide']
        raise Error, 'This VM has no running native window.' unless active?
        AgentVM.run(helper, @vm.running_pid.to_s, 'hide')
        puts 'VM window hidden; the VM and SSH sessions keep running.'
        return
      end
      if @vm.running? && !active?
        unless args == ['--restart']
          raise Error, 'This process was started in strict headless mode. Use vm gui --restart once to enable its window; current SSH sessions will end. Normal starts keep a hidden window ready for later use.'
        end
      end
      binary = helper
      @vm.stop if @vm.running? && !active? && args == ['--restart']
      @vm.start(graphics:true) unless @vm.running?
      AgentVM.run(binary, @vm.running_pid.to_s, 'show')
      puts "Guest desktop opened. Login: #{@vm.config['user']}; vm password copies its password, vm password --show displays it."
      puts 'Use vm gui --hide to hide the window while keeping work running. Closing Tart\'s window stops the VM.'
    end
  end
end
