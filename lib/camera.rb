require_relative 'core'
require_relative 'install'
require_relative 'permission-ui'

module AgentVM
  class Camera
    OBS = '/Applications/OBS.app'.freeze
    GUEST = '/usr/local/libexec/agent-vm'.freeze
    def initialize(vm); @vm = vm; end
    def label; 'local.second-mac.' + @vm.name + '.camera'; end
    def ffmpeg; '/opt/homebrew/bin/ffmpeg'; end
    def guest_path?(path, kind:'-x')
      @vm.ssh('/bin/test', kind, path, capture:true)
      true
    rescue Error
      false
    end
    def self.encoder(binary)
      [binary, '-hide_banner', '-loglevel', 'warning', '-nostdin', '-f', 'rawvideo',
       '-pixel_format', 'bgra', '-video_size', '1280x720', '-framerate', '30', '-i', 'pipe:0', '-an',
       '-c:v', 'h264_videotoolbox', '-realtime', '1', '-b:v', '4M', '-g', '30', '-bf', '0',
       '-pix_fmt', 'yuv420p', '-f', 'mpegts', '-mpegts_flags', '+resend_headers', '-muxdelay', '0', 'pipe:1']
    end
    def source_binary
      source = File.join(__dir__, 'camera-source.m')
      digest = Digest::SHA256.file(source).hexdigest
      bundle = @vm.file('OBS Camera Bridge.app')
      executable = File.join(bundle, 'Contents/MacOS/camera-source')
      marker = @vm.file('camera-source.sha256')
      unless File.executable?(executable) && File.file?(marker) && File.read(marker) == digest
        FileUtils.mkdir_p(File.dirname(executable), mode:0700)
        AgentVM.write(File.join(bundle, 'Contents/Info.plist'), AgentVM.plist('CFBundleIdentifier'=>'local.second-mac.camera.' + @vm.name,
          'CFBundleName'=>'Second Mac OBS Bridge', 'CFBundleDisplayName'=>'Second Mac OBS Bridge', 'CFBundleExecutable'=>'camera-source',
          'CFBundlePackageType'=>'APPL', 'LSUIElement'=>true,
          'NSCameraUsageDescription'=>'Forward only OBS Virtual Camera video to your explicitly enabled Second Mac.'))
        AgentVM.run('/usr/bin/xcrun', 'clang', '-O2', '-fobjc-arc', '-framework', 'Foundation', '-framework', 'AVFoundation',
          '-framework', 'CoreImage', '-framework', 'CoreGraphics', '-framework', 'CoreMedia', '-framework', 'CoreVideo', source, '-o', executable, timeout:120)
        AgentVM.run('/usr/bin/codesign', '--force', '--sign', '-', bundle, capture:true)
        AgentVM.write(marker, digest)
      end
      executable
    end
    def binary
      source = File.join(__dir__, '..', 'guest', 'camera-sink.m')
      digest = Digest::SHA256.file(source).hexdigest
      path = @vm.file('camera-sink-' + digest[0,16])
      unless File.executable?(path)
        AgentVM.run('/usr/bin/xcrun', 'clang', '-O2', '-fobjc-arc', '-framework', 'Foundation',
          '-framework', 'CoreMediaIO', '-framework', 'CoreMedia', '-framework', 'CoreVideo', source, '-o', path, timeout:120)
        AgentVM.run('/usr/bin/codesign', '--force', '--sign', '-', path, capture:true)
      end
      path
    end
    def install_guest_obs
      if guest_path?(OBS, kind:'-d')
        @vm.ssh('/usr/bin/codesign', '--verify', '--strict', '-R',
          '=anchor apple generic and certificate leaf[subject.OU] = "2MMRE5MTB8"', OBS, capture:true)
        return
      end
      installer = Installer.new(@vm.config)
      metadata = @vm.file('obs-release.json')
      installer.download('https://api.github.com/repos/obsproject/obs-studio/releases/latest', metadata)
      asset = JSON.parse(File.read(metadata)).fetch('assets').find { |a| a['name'].end_with?('-macOS-Apple.dmg') }
      raise Error, 'No official Apple Silicon OBS release found.' unless asset && asset['digest'].to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
      image = @vm.file('obs-install.dmg')
      installer.download(asset.fetch('browser_download_url'), image) unless File.file?(image) && 'sha256:'+Digest::SHA256.file(image).hexdigest == asset['digest']
      raise Error, 'OBS release digest mismatch.' unless 'sha256:'+Digest::SHA256.file(image).hexdigest == asset['digest']
      remote = @vm.ssh('/usr/bin/mktemp', '-d', '/private/tmp/second-mac-obs.XXXXXXXX', capture:true).strip
      raise Error, 'Unexpected guest temporary directory.' unless remote.match?(%r{\A/private/tmp/second-mac-obs\.[A-Za-z0-9]+\z})
      AgentVM.run('/usr/bin/scp', '-q', '-F', @vm.file('ssh-config'), image, @vm.name+':'+remote+'/obs.dmg')
      @vm.ssh('/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', remote+'/image', remote+'/obs.dmg', capture:true)
      app = remote+'/image/OBS.app'
      @vm.ssh('/usr/bin/codesign', '--verify', '--deep', '--strict', app, capture:true)
      @vm.ssh('/usr/bin/codesign', '--verify', '--strict', '-R',
        '=anchor apple generic and certificate leaf[subject.OU] = "2MMRE5MTB8"', app, capture:true)
      @vm.root('/usr/bin/ditto', app, OBS)
    ensure
      if remote
        @vm.ssh('/usr/bin/hdiutil', 'detach', remote+'/image', capture:true) rescue nil
        @vm.ssh('/bin/rm', '-rf', remote, capture:true) rescue nil
      end
      File.unlink(image) if image && File.file?(image)
    end
    def setup
      @vm.start unless @vm.running?
      raise Error, 'Camera setup needs guest-only UI control: vm ui enable [--restart].' unless @vm.ui_available?
      install_guest_obs
      @vm.ssh('/opt/homebrew/bin/brew', 'install', 'ffmpeg', capture:true, timeout:600) unless guest_path?(ffmpeg)
      install_helpers
      enable_extension
      puts @vm.ssh(GUEST+'/camera-sink', '--check', capture:true)
      puts 'Guest camera receiver installed. Sharing remains off until vm camera on.'
    end
    def install_helpers
      files = [[GUEST+'/camera-sink', Base64.strict_encode64(File.binread(binary)), 0755],
               [GUEST+'/camera-receiver.rb', Base64.strict_encode64(File.read(File.join(__dir__, '..', 'guest/camera-receiver.rb'))), 0755]]
      @vm.root('/usr/bin/ruby', '-rjson', '-rbase64', '-rfileutils', '-rsecurerandom', '-e', <<~'RUBY', input:JSON.generate(files))
        JSON.parse(STDIN.read).each do |path, encoded, mode|
          FileUtils.mkdir_p(File.dirname(path)); raise 'Unsafe helper path' if File.symlink?(path)
          content = Base64.strict_decode64(encoded)
          next if File.file?(path) && File.binread(path) == content && (File.stat(path).mode & 0777) == mode && File.stat(path).uid.zero?
          temporary = path + '.' + SecureRandom.hex(8)
          begin
            File.open(temporary, File::WRONLY|File::CREAT|File::EXCL, mode) { |f| f.write(content); f.flush; f.fsync }
            File.chmod(mode, temporary); File.rename(temporary, path)
          ensure
            File.unlink(temporary) if File.file?(temporary)
          end
        end
      RUBY
    end
    def enable_extension
      state = @vm.ssh('/usr/bin/systemextensionsctl', 'list', capture:true)
      unless state.lines.any? { |line| line.include?('com.obsproject.obs-studio.mac-camera-extension') && line.include?('[activated enabled]') }
        @vm.ssh('/usr/bin/open', '-a', OBS, capture:true)
        ui = Desktop.new(@vm)
        # Fresh OBS may show its permission review before requesting the camera
        # extension. Producing virtual video needs none of those capture grants.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
        loop do
          page = ui.screen
          if page['rows'].any? { |r| r['text'] == 'Review App Permissions' }
            ui.click_text('Continue')
          elsif page['rows'].any? { |r| r['text'].match?(/camera extension/i) } && page['rows'].any? { |r| r['text'] == 'Open System Settings' }
            ui.click_text('Open System Settings'); break
          elsif page['rows'].any? { |r| r['text'] == 'Camera Extensions' }
            break
          end
          raise Error, 'OBS did not request its guest camera extension. Open guest OBS once, then rerun vm camera setup.' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep 1
        end
        PermissionUI.new(@vm).extension('camera', 'OBS')
      end
    end
    def stop
      system('/bin/launchctl', 'bootout', @vm.domain+'/'+label, out:File::NULL, err:File::NULL)
      # Revoke capture first, including a LaunchServices app left after an
      # abrupt bridge exit. Its timer also detects a released owner lock.
      path = @vm.file('camera.json')
      File.unlink(path) if File.file?(path)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 12
      lock_path = @vm.file('camera-owner.lock')
      if File.file?(lock_path)
        File.open(lock_path, 'r') do |lock|
          until lock.flock(File::LOCK_SH|File::LOCK_NB)
            raise Error, 'Camera bridge is still stopping; retry in a moment.' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            sleep 0.1
          end
        end
      end
    end
    def start
      return unless @vm.config['camera_obs'] && @vm.running?
      return if active?
      stop
      generation = SecureRandom.hex(16)
      path = @vm.file('camera.plist')
      AgentVM.write(path, AgentVM.plist('Label'=>label, 'ProgramArguments'=>['/usr/bin/ruby', __FILE__, @vm.state, @vm.running_pid.to_s, generation],
        'EnvironmentVariables'=>{'AGENT_VM_HOME'=>AgentVM.state_root, 'TART_HOME'=>ENV.fetch('TART_HOME', File.join(Dir.home, '.tart'))},
        'RunAtLoad'=>true, 'KeepAlive'=>false, 'StandardOutPath'=>File::NULL, 'StandardErrorPath'=>@vm.file('camera.log')))
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      begin
        AgentVM.run('/bin/launchctl', 'bootstrap', @vm.domain, path, capture:true)
      rescue Error
        raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.2
        retry
      end
    end
    def active?
      path = @vm.file('camera.json')
      return false unless @vm.running? && File.file?(path)
      data = JSON.parse(File.read(path))
      return false unless data['owner'] == @vm.running_pid
      job = AgentVM.run('/bin/launchctl', 'print', @vm.domain+'/'+label, capture:true)
      job[/^\s*pid = (\d+)$/, 1].to_i == data['pid']
    rescue Error, JSON::ParserError
      false
    end
    def command(args)
      action = args.shift || 'status'
      raise Error, 'Usage: vm camera setup|on|off|status|help' unless args.empty?
      case action
      when 'setup' then setup
      when 'on'
        setup
        AgentVM.run('/opt/homebrew/bin/brew', 'install', 'ffmpeg', timeout:900) unless File.executable?(ffmpeg)
        AgentVM.run('/opt/homebrew/bin/brew', 'install', '--cask', 'obs', timeout:900) unless File.directory?(OBS)
        AgentVM.run('/usr/bin/codesign', '--verify', '--strict', '-R', '=anchor apple generic and certificate leaf[subject.OU] = "2MMRE5MTB8"', OBS, capture:true)
        AgentVM.run(source_binary, '--check', capture:true, timeout:15)
        @vm.config['camera_obs'] = true; @vm.save; start
        puts 'OBS camera sharing enabled. On the host, start OBS Virtual Camera with your chosen scene; approve any host camera consent yourself.'
        puts 'Only video is shared. Use vm microphone on separately for the host default microphone. vm camera off revokes video without rebooting.'
      when 'off'
        @vm.config['camera_obs'] = false; @vm.save; stop
        puts 'OBS camera sharing disabled.'
      when 'status'
        puts "OBS camera: #{@vm.config['camera_obs'] ? 'enabled' : 'disabled'}; bridge #{active? ? 'running' : 'stopped'}"
        puts 'Source: host OBS Virtual Camera only. No default-camera, screen, or audio fallback.'
      when 'help', '--help', '-h'
        puts 'vm camera setup installs the guest receiver and approves its OBS camera extension through guest-only UI.'
        puts 'vm camera on enables forwarding from host OBS Virtual Camera; off stops it immediately. Default: off.'
        puts 'Start Virtual Camera in host OBS. Select OBS Virtual Camera in guest apps. Microphone is a separate opt-in.'
      else raise Error, 'Usage: vm camera setup|on|off|status|help'
      end
    end
    def serve(owner, generation, encoder:nil)
      raise Error, 'Invalid camera owner or generation.' unless owner.is_a?(Integer) && owner > 0 && generation.is_a?(String) && generation.match?(/\A[0-9a-f]{32}\z/)
      raise Error, 'Camera sharing is off or VM changed.' unless @vm.running_pid == owner && @vm.config['camera_obs']
      lock = File.open(@vm.file('camera-owner.lock'), File::RDWR|File::CREAT, 0600)
      raise Error, 'Another OBS bridge still owns this VM; retry in a moment.' unless lock.flock(File::LOCK_EX|File::LOCK_NB)
      children = []
      reader, writer = IO.pipe
      receiver = [@vm.tart, 'exec', '-i', @vm.name, '/usr/bin/ruby', GUEST+'/camera-receiver.rb', generation]
      children << Process.spawn(*receiver, in:reader, out:File::NULL, err:$stderr, pgroup:true)
      reader.close
      if encoder
        # Dependency injection for local synthetic transport verification only.
        children << Process.spawn(*encoder, in:File::NULL, out:writer, err:$stderr, pgroup:true)
      else
        source_binary
        fifo = @vm.file('camera-stream-' + generation)
        AgentVM.run('/usr/bin/mkfifo', '-m', '600', fifo, capture:true)
        codec = self.class.encoder(ffmpeg)
        codec[codec.index('pipe:0')] = fifo
        children << Process.spawn(*codec, in:File::NULL, out:writer, err:$stderr, pgroup:true)
        AgentVM.json_write(@vm.file('camera.json'), {'owner'=>owner, 'pid'=>Process.pid, 'generation'=>generation})
        # LaunchServices gives this small app its own Camera consent identity;
        # running capture through SSH/another command's responsibility can deny it.
        children << Process.spawn('/usr/bin/open', '-n', '-g', '-W', '--stdout', fifo,
          '--stderr', @vm.file('camera-source.log'), @vm.file('OBS Camera Bridge.app'), '--args',
          '--lifetime', @vm.file('camera.json'), generation, in:File::NULL, out:File::NULL, err:$stderr, pgroup:true)
      end
      writer.close
      AgentVM.json_write(@vm.file('camera.json'), {'owner'=>owner, 'pid'=>Process.pid, 'generation'=>generation})
      stopped = false
      %w[TERM INT].each { |signal| Signal.trap(signal) { stopped = true } }
      until stopped || @vm.running_pid != owner
        dead = children.find { |pid| Process.waitpid(pid, Process::WNOHANG) rescue true }
        if dead
          children.delete(dead)
          warn 'OBS video bridge stopped. Start host OBS Virtual Camera, check host camera consent, then run vm camera on.'
          break
        end
        sleep 0.5
      end
    ensure
      path = @vm.file('camera.json')
      begin
        File.unlink(path) if lock && File.file?(path) && JSON.parse(File.read(path))['generation'] == generation
      rescue JSON::ParserError, Errno::ENOENT
      end
      [reader, writer].compact.each { |io| io.close unless io.closed? }
      (children || []).each { |pid| Process.kill('TERM', -pid) rescue Errno::ESRCH }
      (children || []).each do |pid|
        begin
          Timeout.timeout(3) { Process.waitpid(pid) }
        rescue Timeout::Error
          Process.kill('KILL', -pid) rescue Errno::ESRCH
          Process.waitpid(pid) rescue Errno::ECHILD
        rescue Errno::ECHILD
        end
      end
      if lock && generation.is_a?(String) && @vm.running_pid == owner
        @vm.ssh('/usr/bin/pkill', '-f', '^/usr/bin/ruby '+GUEST+'/camera-receiver.rb '+generation+'$', capture:true, timeout:5) rescue nil
      end
      File.unlink(fifo) if fifo && File.exist?(fifo)
      lock.close if lock
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    directory, owner, generation = ARGV
    vm = AgentVM::VM.new(JSON.parse(File.read(File.join(directory, 'config.json'))))
    raise AgentVM::Error, 'Camera state directory does not match VM.' unless vm.state == directory
    AgentVM::Camera.new(vm).serve(Integer(owner), generation)
  rescue StandardError => error
    warn "Camera stopped: #{error.message}"; exit 1
  end
end
