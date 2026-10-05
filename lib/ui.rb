require_relative 'core'
require_relative 'ui-build'
require_relative 'sip'
require 'socket'
require 'base64'

module AgentVM
  class Desktop < Recovery
    def request(value, timeout:180)
      path = File.join(@vm.tart_directory, 'ui.sock')
      raise Error, 'Guest UI is unavailable. Enable it once with vm ui enable --restart, or start an already enabled VM.' unless @vm.running? && File.socket?(path)
      metadata = File.lstat(path)
      raise Error, 'Unsafe VM UI socket.' unless metadata.uid == Process.uid && (metadata.mode & 0077).zero?
      # Relative connect avoids macOS's short Unix-socket pathname limit.
      socket = Dir.chdir(@vm.tart_directory) { UNIXSocket.new('ui.sock') }
      socket.write(JSON.generate(value) + "\n")
      data = +''
      Timeout.timeout(timeout) do
        loop do
          data << socket.readpartial(16384)
          raise Error, 'Unexpectedly large VM UI response.' if data.bytesize > 32*1024*1024
          break if data.end_with?("\n")
        end
      end
      result = JSON.parse(data)
      raise Error, result['error'] if result['error']
      result
    rescue Timeout::Error
      raise Error, 'VM UI operation timed out; the guest is still running.'
    rescue JSON::ParserError, EOFError, SystemCallError => e
      raise Error, "VM UI connection failed: #{e.class}. Restart this guest to restore its controller."
    ensure
      socket.close if socket && !socket.closed?
    end
    def send_command(value, timeout:180); request(value, timeout:timeout); end
    def enabled?; @vm.ui_available?; end
    def live_toggle(value)
      return false unless @vm.running?
      require_relative 'runtime'
      runtime = Runtime.new(@vm)
      return false unless runtime.current.fetch('features', []).include?('live-ui')
      runtime.request('op'=>'ui-set', 'enabled'=>value)
      receipt = JSON.parse(File.read(@vm.file('access-launch.json')))
      raise Error, 'Guest changed during UI update.' unless receipt['pid'] == @vm.running_pid
      receipt['ui_enabled'] = value
      receipt.fetch('configuration')['ui_enabled'] = value
      AgentVM.json_write(@vm.file('access-launch.json'), receipt)
      true
    end
    def enable(restart:false)
      @vm.start if @vm.suspended? && !@vm.running?
      if live_toggle(true)
        @vm.config['ui_enabled'] = true
        @vm.save
        return puts 'Guest-only UI control enabled live; guest macOS, Tart and SSH kept.'
      end
      raise Error, 'Guest UI control requires custom Tart: vm runtime custom. Native desktop viewing remains available with vm gui.' if @vm.config['runtime_mode'] == 'standard'
      binary = UIBuild.new(@vm).install
      attached = false
      if @vm.running? && enabled? && @vm.config['ui_tart'] == binary
        attached = request({'op'=>'status'}, timeout:5)['pid'] == @vm.running_pid rescue false
      end
      if @vm.running? && !attached
        raise Error, 'The guest needs one restart to attach virtual UI control. Run vm ui enable --restart; its sessions will end.' unless restart
        @vm.stop
      end
      @vm.config['ui_enabled'] = true
      @vm.config['ui_tart'] = binary
      @vm.save
      @vm.start unless @vm.running?
      puts 'Guest-only display/input control enabled. No guest UI helper or host Accessibility permission is used.'
    end
    def disable(restart:false)
      was_running = @vm.running?
      live = live_toggle(false)
      if was_running && enabled? && !live
        raise Error, 'Detaching the controller needs a restart. Run vm ui disable --restart; its sessions will end.' unless restart
        @vm.stop
      end
      @vm.config['ui_enabled'] = false
      @vm.config['permissions_auto'] = false
      @vm.config['guest_control'] = false
      @vm.save
      require_relative 'permissions'
      Permissions.new(@vm).stop_watcher
      require_relative 'guest-control'
      GuestControl.new(@vm).stop
      @vm.start if was_running && !@vm.running?
      puts 'Virtual UI controller and automatic approval disabled. Guest SIP and existing grants are unchanged.'
    end
    def click_text(value)
      rows = screen.fetch('rows').select { |r| r['text'].casecmp(value).zero? }
      raise Error, "Expected one visible match for #{value.inspect}; found #{rows.length}. Use vm ui inspect or click X Y." unless rows.length == 1
      click(rows.first)
    end
    def keyboard(shortcut)
      parts = shortcut.downcase.split('+')
      name = parts.pop
      modifiers = {'shift'=>1<<17, 'ctrl'=>1<<18, 'control'=>1<<18, 'alt'=>1<<19, 'option'=>1<<19, 'cmd'=>1<<20, 'command'=>1<<20}
      flags = parts.reduce(0) { |all,p| all | modifiers.fetch(p) { raise Error, 'Unknown key modifier.' } }
      code = KEYS[name] || PLAIN[name]
      raise Error, 'Unknown key. Examples: return, tab, cmd+shift+p.' unless code
      key(code, flags:flags)
    end
    def approve_once
      page = screen
      target = self.class.consent_button(page)
      return false unless target
      click(target)
      true
    end
    def self.consent_button(page)
      rows, width, height = page.fetch('rows'), page.fetch('width', 1024), page.fetch('height', 768)
      deny = rows.select { |r| r['text'].match?(/\A(?:Don.t Allow|Deny|Not Now)\z/i) }
      allow = rows.select { |r| r['text'].match?(/\A(?:Allow|Always Allow|OK|Allow While Using the App)\z/i) }
      candidates = allow.product(deny).select do |yes, no|
        x, y = (yes['x'] + no['x']) / 2.0, (yes['y'] + no['y']) / 2.0
        next false unless (yes['y']-no['y']).abs < 32 && (yes['x']-no['x']).abs.between?(30, 420)
        next false unless (x-width/2.0).abs <= width/8.0 && y.between?(100, height-90)
        # Match text immediately above the centered button pair. Onboarding
        # apps can show pictures of permission dialogs behind the real dialog.
        prompt = rows.select { |r| (r['x']-x).abs < 210 && r['y'].between?(y-260, y-15) }.map { |r| r['text'] }.join(' ')
        prompt.match?(/(?:would like|wants) to (?:access|control|record|use|find|send|receive|filter)|allow .*(?:access|notifications|record)|allow .* to (?:find|use) /i)
      end
      return candidates.first.first if candidates.length == 1
      return nil unless candidates.empty?
      # LuLu uses its own movable alert instead of Apple's centered consent.
      # Require its title, connection prompt and a unique Allow/Block pair.
      titles = rows.select { |r| r['text'] == 'LuLu Alert' }
      return nil unless titles.length == 1
      title = titles.first
      pairs = allow.product(rows.select { |r| r['text'].casecmp('Block').zero? }).select do |yes, no|
        next false unless (yes['y']-no['y']).abs < 10 && (yes['x']-no['x']).abs.between?(50, 250)
        next false unless yes['y'].between?(title['y']+80, title['y']+300)
        rows.any? { |r| r['text'].match?(/\Ais connecting to .+/i) && r['y'].between?(title['y'], yes['y']-15) }
      end
      pairs.length == 1 ? pairs.first.first : nil
    end
    def command(args)
      action = args.shift || 'status'
      if %w[enable disable].include?(action)
        raise Error, "Usage: vm ui #{action} [--restart]" unless [[], ['--restart']].include?(args)
        return public_send(action, restart:args == ['--restart'])
      end
      raise Error, 'Enable virtual display control first: vm ui enable [--restart].' unless enabled?
      raise Error, 'Start this VM first with vm start.' unless @vm.running?
      case action
      when 'status' then puts JSON.pretty_generate(request({'op'=>'status'}, timeout:5))
      when 'inspect' then puts JSON.pretty_generate(screen)
      when 'screenshot'
        raise Error, 'Usage: vm ui screenshot > image.png' unless args.empty?
        $stdout.binmode
        $stdout.write(Base64.strict_decode64(request({'op'=>'screenshot'}).fetch('png')))
      when 'click-text'
        raise Error, 'Usage: vm ui click-text LABEL' unless args.length == 1
        click_text(args.first)
      when 'click'
        raise Error, 'Usage: vm ui click X Y' unless args.length == 2
        x, y = args.map { |n| Float(n) }
        raise Error, 'Guest coordinates must be finite numbers.' unless x.finite? && y.finite?
        send_command({'op'=>'click','x'=>x,'y'=>y})
      when 'key'
        raise Error, 'Usage: vm ui key SHORTCUT' unless args.length == 1
        keyboard(args.first)
      when 'type'
        raise Error, 'Usage: vm ui type < text (US keyboard, printable ASCII)' unless args.empty?
        value = $stdin.read(65537)
        raise Error, 'Type accepts up to 64 KiB.' if value.bytesize > 65536
        type(value)
      when 'show', 'hide' then request({'op'=>action}, timeout:5)
      when 'approve' then puts(approve_once ? 'Approved a guest permission dialog.' : 'No recognized guest permission dialog.')
      else raise Error, 'Usage: vm ui enable|disable [--restart]|status|inspect|screenshot|click-text LABEL|click X Y|key SHORTCUT|type|show|hide|approve'
      end
    rescue ArgumentError
      raise Error, 'Invalid guest UI argument.'
    end
  end
end
