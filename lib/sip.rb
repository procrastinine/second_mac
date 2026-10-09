require_relative 'core'
require_relative 'gui'
require 'base64'

module AgentVM
  # Local, deterministic OCR over the Recovery VM's own window. SIP-off is
  # offline; restoring Full Security needs Apple's online signing service and
  # uses Tart/Softnet with the usual host/LAN blocks, no shares or forwards.
  class Recovery
    KEYS = {'return'=>36, 'enter'=>36, 'escape'=>53, 'tab'=>48, 'space'=>49,
            'left'=>123, 'right'=>124, 'down'=>125, 'up'=>126, 'f2'=>120}.freeze
    LETTERS = ('a'..'z').zip([0,11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6]).to_h.freeze
    PLAIN = LETTERS.merge('1'=>18,'2'=>19,'3'=>20,'4'=>21,'6'=>22,'5'=>23,'='=>24,'9'=>25,'7'=>26,'-'=>27,
                          '8'=>28,'0'=>29,']'=>30,'['=>33,"'"=>39,';'=>41,'\\'=>42,','=>43,'/'=>44,'.'=>47,' '=>49,'`'=>50).freeze
    SHIFTED = '!@#$%^&*()_+{}:"|<>?~'.chars.zip('1234567890-=[];\'\\,./`'.chars).to_h.freeze
    def initialize(vm)
      @vm = vm
    end
    def build
      source = File.join(__dir__, 'recovery.m')
      display = File.join(__dir__, 'display')
      digest = Digest::SHA256.hexdigest(([source] + Dir.glob(File.join(display, '**', '*')).select { |p| File.file?(p) }.sort).map { |p| Digest::SHA256.file(p).hexdigest }.join)
      binary = @vm.file('recovery-native')
      unless File.executable?(binary) && File.file?(@vm.file('recovery.sha256')) && File.read(@vm.file('recovery.sha256')) == digest
        AgentVM.run('/usr/bin/xcrun', 'clang', '-O2', '-fmodules', '-fobjc-arc', '-mmacosx-version-min=14.4',
                    '-fmodules-cache-path=' + @vm.file('swift-module-cache'),
                    '-framework', 'AppKit', '-framework', 'Virtualization', '-framework', 'Vision', '-framework', 'ScreenCaptureKit',
                    '-I' + File.join(display, 'include'), source, File.join(display, 'Display.m'), File.join(display, 'Keyboard.m'), '-o', binary, timeout:120)
        entitlement = @vm.file('recovery-entitlements.plist')
        AgentVM.write(entitlement, AgentVM.plist('com.apple.security.virtualization'=>true))
        AgentVM.run('/usr/bin/codesign', '--force', '--sign', '-', '--entitlements', entitlement, binary, capture:true)
        AgentVM.write(@vm.file('recovery.sha256'), digest)
      end
      binary
    end
    def open(network:false)
      log = File.open(@vm.file('recovery.log'), 'w', 0600)
      @network = network
      if network
        require_relative 'ui'
        require_relative 'network'
        binary = UIBuild.new(@vm).install
        networking = Network.new(@vm)
        networking.prepare
        blocks = AgentVM.blocked_networks(AgentVM.run('/sbin/ifconfig', capture:true))
        environment = {'SECOND_MAC_UI'=>'1', 'DO_NOT_TRACK'=>'1', 'OTEL_SDK_DISABLED'=>'true',
                      }.merge(networking.environment)
        args = [binary, 'run', @vm.name, '--recovery', '--no-graphics', '--no-audio', '--no-clipboard',
                '--no-usb-accessories', '--net-softnet', '--net-softnet-block=' + blocks.uniq.join(',')]
        pid = Process.spawn(environment, *args, in:File::NULL, out:log, err:log)
        @process = Process.detach(pid)
        @controller = Desktop.new(@vm)
      else
        @input, @output, @process = Open3.popen2(build, @vm.tart_directory, err:log)
        @input.sync = true
      end
      log.close
      AgentVM.json_write(@vm.file('recovery-process.json'), {'pid'=>@process.pid})
      if network
        @vm.wait_for(90, 'Preparing isolated Recovery') do
          raise Error, 'Recovery process exited; see the private recovery.log.' unless @process.alive?
          @controller.request({'op'=>'status'}, timeout:5)['pid'] == @process.pid
        end
      else
        read_response(60)
      end
      yield self
    ensure
      # Closing the private input pipe also stops an abandoned Recovery runner.
      @input.close if @input && !@input.closed?
      begin
        Process.kill('INT', @process.pid) if network && @process && @process.alive?
      rescue Errno::ESRCH
      end
      if @process && !@process.join(10)
        Process.kill('TERM', @process.pid) rescue Errno::ESRCH
        @process.join(10)
      end
      @output.close if @output && !@output.closed?
      log.close if log && !log.closed?
      File.unlink(@vm.file('recovery-process.json')) if File.file?(@vm.file('recovery-process.json'))
    end
    def read_response(timeout)
      raise Error, 'Recovery did not respond before the deadline; see vm logs and the private recovery.log.' unless IO.select([@output], nil, nil, timeout)
      line = @output.gets
      raise Error, 'Recovery stopped unexpectedly; see the private recovery.log.' unless line
      value = JSON.parse(line)
      raise Error, value['error'] if value['error']
      value
    end
    def send_command(value, timeout:120)
      if @controller
        if value['op'] == 'stop'
          Process.kill('INT', @process.pid)
          return {'ok'=>true}
        end
        return @controller.request(value, timeout:timeout)
      end
      @input.puts(JSON.generate(value))
      read_response(timeout)
    rescue Errno::EPIPE, JSON::ParserError
      raise Error, 'Recovery control channel closed or returned invalid data.'
    end
    def screen
      send_command({'op'=>'screen'})
    end
    def key(name, flags:0, hold_ms:nil)
      code = name.is_a?(Integer) ? name : KEYS.fetch(name)
      command = {'op'=>'key', 'code'=>code, 'flags'=>flags}
      command['hold_ms'] = hold_ms unless hold_ms.nil?
      send_command(command)
      sleep 0.15
    end
    def type(text)
      self.class.validate_text(text)
      text.each_char do |char|
        shifted = char.match?(/[A-Z]/) || SHIFTED.key?(char)
        plain = SHIFTED.fetch(char, char.downcase)
        key(PLAIN.fetch(plain), flags:shifted ? 1 << 17 : 0)
      end
    end
    def self.validate_text(text)
      raise Error, 'Recovery typing currently supports the US keyboard and printable ASCII only.' unless text.chars.all? { |c| PLAIN.key?(c.downcase) || SHIFTED.key?(c) }
    end
    def click(row)
      send_command({'op'=>'click', 'x'=>row.fetch('x'), 'y'=>row.fetch('y')})
      sleep 0.5
    end
    def wait_for(pattern, timeout:120)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        page = screen
        return page if page.fetch('rows').any? { |row| row['text'].match?(pattern) }
        raise Error, "Recovery did not reach the expected screen (#{pattern.source}). No further keys were sent." if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 2
      end
    end
    def text(page)
      page.fetch('rows').map { |row| row.fetch('text') }.join("\n")
    end
    def change(enabled, user, password)
      puts "Opening paired Recovery (#{@network ? 'isolated internet for Apple signing' : 'offline'}; guest window only)…"
      page = wait_for(/Options|Utilities|Language|English/i, timeout:180)
      unless text(page).include?('Utilities')
        # Selecting Options reveals Continue; entering the highlighted option
        # can take two Returns on newer recoveryOS builds.
        if (row = page['rows'].find { |item| item['text'] == 'Options' })
          key('right'); key('right')
          key('return')
          sleep 2
          page = screen
          key('return') if text(page).include?('Options')
        end
        page = wait_for(/Utilities|English|Language/i, timeout:180)
        if !text(page).include?('Utilities') && text(page).match?(/English|Language/i)
          row = page['rows'].find { |item| item['text'].match?(/^English$/) }
          click(row) if row
          key('return')
        end
        page = wait_for(/Utilities/, timeout:180)
      end
      click(page['rows'].find { |row| row['text'].include?('Utilities') })
      page = wait_for(/^Terminal$/, timeout:15)
      click(page['rows'].find { |row| row['text'] == 'Terminal' })
      wait_for(/(?:bash|zsh|sh)-\d/, timeout:30)
      sleep 2
      if @network
        # The VPN-compatible router supplies its own private DNS endpoint.
        # Native Softnet blocks the physical gateway, so Recovery uses Quad9.
        puts 'Configuring Recovery DNS and checking the Apple signing connection…'
        dns = Network.new(@vm).state['backend'] == 'vpn' ? '192.168.127.1' : '9.9.9.9 149.112.112.112'
        type('s=$(echo "show State:/Network/Global/IPv4" | scutil | awk \'/PrimaryService/{print $3}\'); printf "d.init\\nd.add ServerAddresses * ' + dns + '\\nset State:/Network/Service/%s/DNS\\nquit\\n" "$s" | scutil')
        key('return')
        sleep 2
        type('curl -4 -IsS --connect-timeout 10 --max-time 20 https://gs.apple.com >/dev/null && echo NETWORK_READY')
        key('return')
        wait_for(/^NETWORK_READY$/, timeout:35)
      end
      puts "Requesting SIP #{enabled ? 'enable' : 'disable'} in guest Recovery…"
      type(enabled ? 'csrutil enable' : 'csrutil disable')
      key('return')
      page = wait_for(/\[y\/n\]|authorized user|password|already (enabled|disabled)/i, timeout:30)
      if text(page).match?(/\[y\/n\]/i)
        type('y'); key('return')
        page = wait_for(/authorized user|password/i, timeout:30)
      end
      if text(page).match?(/authorized user/i)
        type(user); key('return')
        page = wait_for(/password/i, timeout:30)
      end
      if text(page).match?(/password/i)
        # Never send credentials before an observed password prompt. The value
        # travels through a private pipe, never argv, logs or a host clipboard.
        type(password); key('return')
      end
      desired = enabled ? /system integrity protection (?:is on|enabled|has been enabled)/i : /system integrity protection (?:is off|disabled|has been disabled)/i
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120
      loop do
        page = screen
        value = text(page)
        break if value.match?(desired) || value.match?(enabled ? /successfully enabled system integrity protection/i : /successfully disabled system integrity protection/i)
        if value.match?(/csrutil:.*(?:failed|error)|authentication failed|not connected to.*internet/i)
          raise Error, 'Recovery rejected the SIP change. Normal macOS will be booted to verify the unchanged policy; see the guest Recovery screen when troubleshooting.'
        end
        raise Error, 'Recovery did not confirm the SIP change before the deadline.' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 2
      end
      puts 'Recovery accepted the change; shutting it down before independent verification…'
      type('sync; shutdown -h now'); key('return')
      unless @process.join(45)
        send_command({'op'=>'stop'}, timeout:30)
      end
    end
  end

  class SIP
    def initialize(vm); @vm = vm; end
    def state
      output = @vm.ssh('/usr/bin/csrutil', 'status', capture:true)
      return 'on' if output.strip == 'System Integrity Protection status: enabled.'
      return 'off' if output.strip == 'System Integrity Protection status: disabled.'
      raise Error, 'Guest reports a custom or unrecognized SIP policy: ' + output.strip
    end
    def command(args)
      mode = args.empty? ? 'status' : args.first
      mode = {'enable'=>'on', 'disable'=>'off'}.fetch(mode, mode)
      raise Error, 'Usage: vm sip [status|on|off]. Changing SIP reboots this guest.' unless args.length <= 1 && %w[status on off].include?(mode)
      was_running = @vm.running?
      visible = was_running && GUI.new(@vm).active? && !GUI.new(@vm).hidden?
      Recovery.validate_text(@vm.config['user'])
      Recovery.validate_text(@vm.password)
      recovery = Recovery.new(@vm)
      if mode == 'on'
        require_relative 'ui-build'
        UIBuild.new(@vm).install
      elsif mode == 'off'
        recovery.build
      end
      @vm.start unless was_running
      model = @vm.ssh('/usr/sbin/sysctl', '-n', 'hw.model', capture:true).strip
      raise Error, 'SIP commands are restricted to an Apple virtual machine.' unless model.start_with?('VirtualMac')
      current = state
      if mode != 'status' && current != mode
        @vm.root('/usr/bin/true')
        puts 'Changing guest SIP requires a reboot; existing guest sessions will end.'
        @vm.with_lifecycle_lock do
          @vm.stop_unlocked
          recovery_error = nil
          begin
            recovery.open(network:mode == 'on') { |session| session.change(mode == 'on', @vm.config['user'], @vm.password) }
          rescue Error => error
            # Recovery wording can change after csrutil has already applied the
            # policy. Normal macOS is the authority; restore a usable boot even
            # when navigation failed, then report the actual state.
            recovery_error = error
          end
          @vm.launch_unlocked(graphics:visible ? true : nil)
          @vm.wait_for(30, 'Waiting for normal boot') { @vm.running? }
          @vm.start
          current = state
          unless current == mode
            raise Error, "SIP verification failed: expected #{mode}, observed #{current}. #{recovery_error&.message}".strip
          end
        end
      end
      puts "Guest SIP: #{current == 'on' ? 'enabled' : 'disabled'} (verified in normal macOS)."
      @vm.stop unless was_running
    end
  end
end
