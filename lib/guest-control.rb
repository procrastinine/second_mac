require_relative 'core'
require_relative 'ui'
require_relative 'permissions'
require_relative 'service-modes'
require_relative '../guest/permissions'
require 'net/http'
require 'webrick'

module AgentVM
  # This is a capability for one running guest, not a remote vm CLI. In
  # particular it cannot change SIP, sharing, forwards, or its own authorization.
  class GuestControlAPI
    class Rejected < Error
      attr_reader :status
      def initialize(status, message); @status = status; super(message); end
    end
    FIELDS = {'status'=>[], 'capabilities'=>[], 'approve'=>[], 'inspect'=>[], 'screenshot'=>[],
              'click'=>%w[x y], 'click-text'=>['text'], 'key'=>['key'], 'type'=>['text'],
              'grant'=>%w[app permissions], 'revoke'=>%w[app permissions], 'check'=>%w[app permissions],
              'extension'=>%w[kind app]}.merge(MacControlCommands::FIELDS).freeze
    LIMIT = 16 * 1024
    def initialize(vm, token, active)
      @vm, @token, @active = vm, token, active
      @desktop, @permissions, @busy = Desktop.new(vm), Permissions.new(vm), Mutex.new
    end
    def reject(status, text); raise Rejected.new(status, text); end
    def valid_token?(value)
      expected = 'Bearer ' + @token
      return false unless value && value.bytesize == expected.bytesize
      value.bytes.zip(expected.bytes).reduce(0) { |diff, (a,b)| diff | (a ^ b) }.zero?
    end
    def dispatch(value)
      reject(400, 'Expected a JSON object.') unless value.is_a?(Hash)
      op = value['op']
      reject(403, 'Operation is outside Mac control scope.') unless FIELDS.key?(op)
      pointer = MacControlCommands::POINTER.include?(op)
      if pointer || op == 'key'
        begin
          pointer ? MacControlCommands.validate_pointer(value) : MacControlCommands.validate_key(value)
        rescue MacControlCommands::Error => e
          reject(400, e.message)
        end
      else
        reject(400, 'Unexpected or missing arguments.') unless value.keys.sort == (FIELDS[op] + ['op']).sort
      end
      case op
      when 'status' then {'enabled'=>true, 'scope'=>'this Mac\'s UI and app permissions'}
      when 'capabilities' then @desktop.capabilities
      when 'approve' then {'approved'=>@desktop.approve_once}
      when 'inspect' then @desktop.screen
      when 'screenshot' then @desktop.request({'op'=>'screenshot'})
      when *MacControlCommands::POINTER then @desktop.pointer(value)
      when 'type'
        begin
          MacControlCommands.validate_text(value['text'])
        rescue MacControlCommands::Error => e
          reject(400, e.message)
        end
        @desktop.type(value['text'])
        {'ok'=>true}
      when 'key'
        @desktop.keyboard(value['key'], hold_ms:value['hold_ms'])
        {'ok'=>true}
      when 'click-text'
        text = value['text']
        reject(400, 'Expected nonempty text of at most 512 bytes.') unless text.is_a?(String) && (1..512).cover?(text.bytesize) && !text.match?(/[\x00-\x1f]/)
        @desktop.click_text(text)
        {'ok'=>true}
      when 'extension'
        kind, app = value.values_at('kind', 'app')
        reject(400, 'Choose camera, network, or filesystem and the exact app label.') unless %w[camera network filesystem].include?(kind) && app.is_a?(String) && app.bytesize.between?(1,100) && !app.match?(/[\x00-\x1f]/)
        require_relative 'permission-ui'
        {'output'=>PermissionUI.new(@vm).extension(kind, app)}
      when 'grant', 'revoke', 'check'
        app, names = value.values_at('app', 'permissions')
        reject(400, 'Choose an absolute app or executable path on this Mac.') unless app.is_a?(String) && app.start_with?('/') && app.bytesize <= 4096 && !app.match?(/[\x00-\x1f]/)
        reject(400, 'Choose explicit permission names, or all.') unless names.is_a?(Array) && (1..32).cover?(names.length) && names.all? { |n| n.is_a?(String) && (GuestPermissions::SERVICES.key?(n) || n == 'all' || n.match?(/\Aapple-events:[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+\z/)) }
        reject(400, 'Use all by itself.') if names.include?('all') && names != ['all']
        {'output'=>op == 'check' ? @permissions.direct([op, app, *names], capture:true) : @permissions.change(op, app, names)}
      end
    end
    def handle(req, res)
      res['Content-Type'] = 'application/json'
      res['Cache-Control'] = 'no-store'
      res['Connection'] = 'close'
      # Consume bounded bodies even for a rejected token. Closing a TCP socket
      # with unread bytes can reset the connection and erase the error response.
      # Grossly oversized/chunked requests are closed without reading them.
      res.keep_alive = false
      size = req['content-length']
      reject(413, 'Request body is missing or too large.') unless !req['transfer-encoding'] && size && size.match?(/\A\d{1,5}\z/) && (1..65536).cover?(size.to_i)
      body = Timeout.timeout(5) { req.body }
      reject(413, 'Request body is too large.') if size.to_i > LIMIT
      reject(400, 'Invalid request size.') unless body && body.bytesize == size.to_i
      reject(403, 'Mac control is no longer active.') unless @active.call
      reject(401, 'Invalid Mac control token.') unless valid_token?(req['authorization'])
      reject(403, 'Browser-origin requests are not supported.') if req['origin'] || req['sec-fetch-site']
      reject(400, 'Use POST /v1/control with a JSON body.') unless req.request_method == 'POST' && req.unparsed_uri == '/v1/control' && req['content-type'] == 'application/json'
      value = JSON.parse(body)
      # Health checks must work during a long OCR/input operation; otherwise
      # vm start could mistake a busy controller for a dead service and replace it.
      return res.body = JSON.generate(dispatch(value)) if value == {'op'=>'status'}
      reject(409, 'Another Mac control action is in progress; retry after it finishes.') unless (locked = @busy.try_lock)
      reject(403, 'Mac control is no longer active.') unless @active.call
      res.body = JSON.generate(dispatch(value))
    rescue Rejected => e
      res.status, res.body = e.status, JSON.generate('error'=>e.message)
    rescue Desktop::UnsupportedInput => e
      res.status, res.body = 422, JSON.generate('error'=>e.message)
    rescue JSON::ParserError
      res.status, res.body = 400, JSON.generate('error'=>'Invalid JSON.')
    rescue Timeout::Error
      res.status, res.body = 408, JSON.generate('error'=>'Request body timed out.')
    rescue StandardError => e
      # Never return host paths, subprocess arguments, or exception backtraces.
      message = e.message.include?('Direct grants require guest SIP disabled') ?
        'Direct grants require SIP off. Use approve for a visible dialog, or ask your administrator to review the system policy.' :
        'Operation failed. Check the app, visible screen and permission names; ask your administrator for further diagnostics.'
      res.status, res.body = 422, JSON.generate('error'=>message)
    ensure
      @busy.unlock if locked
    end
    def server
      WEBrick::HTTPServer.new(BindAddress:'127.0.0.1', Port:0, MaxClients:4,
        RequestTimeout:5, DoNotReverseLookup:true, AccessLog:[],
        ServerSoftware:'Mac Control',
        Logger:WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL)).tap do |server|
        server.mount_proc('/') { |req,res| handle(req,res) }
      end
    end
  end

  class GuestControl
    include ServiceModes
    def initialize(vm); @vm = vm; end
    def label; 'local.second-mac.' + @vm.name + '.guest-control'; end
    def state_path; @vm.file('guest-control.json'); end
    def session_path; @vm.file('guest-control-once.json'); end
    def state
      JSON.parse(File.read(state_path))
    rescue Errno::ENOENT, JSON::ParserError
      {}
    end
    def autostart?; service_record(@vm.file('config.json'))['guest_control'] == true; end
    def save_autostart(value); @vm.config['guest_control'] = value; end
    def enabled?; @vm.ui_available? && requested?; end
    def generation_active?(owner, generation)
      enabled? && @vm.running_pid == owner && state['generation'] == generation
    end
    def active?
      current = state
      return false unless current['owner'].to_i > 0 && generation_active?(current['owner'], current['generation'])
      request = Net::HTTP::Post.new('/v1/control', 'Content-Type'=>'application/json', 'Authorization'=>'Bearer ' + current.fetch('token'))
      request.body = '{"op":"status"}'
      client = Net::HTTP.new('127.0.0.1', current.fetch('host_port'), nil)
      client.open_timeout = client.read_timeout = 2
      client.request(request).code == '200'
    rescue StandardError
      false
    end
    def lock
      File.open(@vm.file('guest-control.lock'), File::RDWR | File::CREAT, 0600) do |file|
        raise Error, 'Another guest-control mode change is in progress.' unless file.flock(File::LOCK_EX | File::LOCK_NB)
        yield
      end
    end
    def stop(revoke_session:true)
      # Unlink first: even an existing HTTP connection fails authorization now.
      File.unlink(state_path) if File.file?(state_path)
      clear_session if revoke_session
      system('/bin/launchctl', 'bootout', @vm.domain + '/' + label, out:File::NULL, err:File::NULL)
    end
    def start
      return unless enabled? && @vm.running?
      starting = false
      lock do
        return if active?
        starting = true
        stop(revoke_session:false)
        owner = @vm.running_pid
        raise Error, 'Enable guest-only UI first: vm ui enable [--restart].' unless @vm.ui_available?
        path = @vm.file('guest-control.plist')
        AgentVM.write(path, AgentVM.plist('Label'=>label, 'ProgramArguments'=>[
          '/usr/bin/ruby', File.join(__dir__, 'cli.rb'), '--name', @vm.name, 'guest-control', 'serve', owner.to_s],
          'EnvironmentVariables'=>{'AGENT_VM_HOME'=>AgentVM.state_root, 'TART_HOME'=>ENV.fetch('TART_HOME', File.join(Dir.home,'.tart')), 'LANG'=>'en_US.UTF-8', 'LC_ALL'=>'en_US.UTF-8'},
          'RunAtLoad'=>true, 'KeepAlive'=>{'SuccessfulExit'=>false}, 'ThrottleInterval'=>5, 'ExitTimeOut'=>3,
          'StandardOutPath'=>File::NULL, 'StandardErrorPath'=>@vm.file('guest-control.log')))
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        begin
          AgentVM.run('/bin/launchctl', 'bootstrap', @vm.domain, path, capture:true)
        rescue Error
          raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.2
          retry
        end
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        failed = lambda do
          next nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 2
          job, status = Open3.capture2e('/bin/launchctl', 'print', @vm.domain + '/' + label)
          if !status.success? || job.match?(/^\s*state = (?:not running|exited)$/)
            'Guest-control service exited; inspect ' + @vm.file('guest-control.log')
          end
        end
        @vm.wait_for(45, 'Starting scoped guest control', abort_if:failed) { active? }
      end
    rescue StandardError
      stop(revoke_session:false) if starting
      raise
    end
    def install_client(port, token)
      Permissions.new(@vm).install_client
      # Only guest-local paths and this boot's capability are sent over stdin.
      payload = {'config'=>{'port'=>port, 'token'=>token}}
      script = <<~'RUBY'
        require 'json'; require 'fileutils'; require 'securerandom'
        value = JSON.parse(STDIN.read)
        base = File.join(Dir.home, '.config/second-mac')
        FileUtils.mkdir_p(base)
        File.chmod(0700, base)
        [[File.join(base,'control.json'), JSON.generate(value.fetch('config')), 0600]].each do |path,content,mode|
          tmp = path + '.' + SecureRandom.hex(8)
          File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, mode) { |f| f.write(content) }
          File.rename(tmp, path)
        end
      RUBY
      @vm.ssh('/usr/bin/ruby', '-e', script, input:JSON.generate(payload), capture:true, timeout:20)
    end
    def serve(owner)
      raise Error, 'Invalid VM owner process.' unless owner.match?(/\A[1-9]\d*\z/)
      owner = owner.to_i
      # A launchd retry after shutdown/revocation must exit successfully instead
      # of keeping an inactive service alive.
      return unless enabled? && @vm.running_pid == owner
      token, generation = SecureRandom.hex(32), SecureRandom.hex(16)
      api = GuestControlAPI.new(@vm, token, -> { generation_active?(owner, generation) })
      server = api.server
      port = server.listeners.first.addr[1]
      socket = @vm.control_socket('guest-control-' + generation)
      # Keep SSH as an owned foreground child. A dynamic reverse port avoids
      # conflicts with guest services and ordinary vm ports entries.
      # Probe only this service tunnel. Interactive SSH retains its sleep-safe
      # settings; a guest reboot can otherwise leave this channel half open.
      pid = Process.spawn(*@vm.ssh_args, '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2', '-M', '-S', socket, '-NT', @vm.name,
        in:File::NULL, out:File::NULL, err:File::NULL)
      child = Process.detach(pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      until File.socket?(socket)
        raise Error, 'Guest-control forward did not start.' unless child.alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.1
      end
      remote = AgentVM.run(*@vm.ssh_args, '-S', socket, '-O', 'forward', '-o', 'ExitOnForwardFailure=yes',
        '-R', "127.0.0.1:0:127.0.0.1:#{port}", @vm.name, capture:true, timeout:10).strip
      raise Error, 'Unexpected guest forward port.' unless remote.match?(/\A\d{1,5}\z/) && (1024..65535).cover?(remote.to_i)
      install_client(remote.to_i, token)
      raise Error, 'Guest-control mode was revoked during startup.' unless enabled? && @vm.running_pid == owner
      AgentVM.json_write(state_path, {'owner'=>owner, 'generation'=>generation, 'token'=>token,
        'host_port'=>port, 'guest_port'=>remote.to_i})
      %w[TERM INT].each { |signal| trap(signal) { server.shutdown } }
      retry_forward = false
      monitor = Thread.new do
        loop do
          sleep 0.5
          break unless generation_active?(owner, generation) && child.alive?
        end
        retry_forward = generation_active?(owner, generation)
        server.shutdown
      end
      server.start
      raise Error, 'Guest-control channel disconnected; retrying while this VM is running.' if retry_forward
    ensure
      monitor.kill if monitor
      server.shutdown if server
      if child && child.alive?
        Process.kill('TERM', child.pid) rescue Errno::ESRCH
        unless child.join(2)
          Process.kill('KILL', child.pid) rescue Errno::ESRCH
          child.join
        end
      end
      File.unlink(socket) if socket && File.socket?(socket)
      File.unlink(state_path) if generation && state['generation'] == generation
      begin
        if owner.is_a?(Integer) && @vm.running_pid != owner && File.file?(session_path)
          saved = JSON.parse(File.read(session_path))
          File.unlink(session_path) if saved['owner'] == owner
        end
      rescue Errno::ENOENT, JSON::ParserError
      end
    end
    def command(args)
      action = args.shift || 'status'
      return serve(args.fetch(0)) if action == 'serve'
      if action == 'autostart'
        mode = args.shift || 'status'
        raise Error, 'Usage: vm guest-control autostart on|off|status' unless args.empty? && %w[on off status].include?(mode)
        if mode != 'status'
          raise Error, 'Enable guest UI first: vm ui enable [--restart].' if mode == 'on' && !@vm.ui_available?
          set_autostart(mode == 'on')
        end
        puts "mac-control autostart: #{autostart? ? 'on' : 'off'}. Current-run access is unchanged."
        return
      end
      once = %w[on off].include?(action) && args == ['--once']
      raise Error, 'Usage: vm guest-control on|off [--once] | status | autostart on|off|status (SIP stays host-only)' unless args.empty? || once
      case action
      when 'status'
        status = if !enabled? then 'disabled'
                 elsif active? then 'enabled and active'
                 elsif @vm.running? then 'enabled but unavailable; run vm guest-control on to retry'
                 else 'enabled; inactive until VM starts'
                 end
        puts "Guest control: #{status}"
        puts "mac-control autostart: #{autostart? ? 'on' : 'off'}"
        puts 'Scope: this guest UI and app permissions. SIP, VM lifecycle and host access rules stay host-only.'
      when 'on'
        raise Error, 'Enable the guest UI controller first: vm ui enable [--restart].' unless @vm.ui_available?
        lock { select_mode(true, once:once) }
        start if @vm.running?
        puts "Guest control enabled#{once ? ' for this run' : ' with autostart'}. Inside the guest: mac-control help. Stopping the VM revokes its token and forward."
      when 'off'
        lock { select_mode(false, once:once); stop(revoke_session:false) }
        puts "Guest control revoked#{once ? ' for this run' : ''} and its private forward removed. Existing app grants are retained."
      else raise Error, 'Usage: vm guest-control on|off|status'
      end
    end
  end
end
