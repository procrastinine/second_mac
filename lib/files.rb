require_relative 'core'
require 'socket'
module AgentVM
  class Files
    def initialize(vm)
      @vm = vm
      @socket = vm.control_socket('files')
      @mount = File.join(Dir.home, 'VMs', vm.name)
      @label = "local.agent-vm.#{vm.name}.files"
    end
    def mounted?
      AgentVM.run('/sbin/mount', capture:true).lines.any? { |l| l.include?(" on #{@mount} (smbfs,") }
    end
    def mount(open_finder: true)
      with_lock { mount_unlocked }
      puts "Guest root mounted at #{@mount}"
      AgentVM.run('/usr/bin/open', @mount) if open_finder
    end
    def with_lock
      FileUtils.mkdir_p(@vm.state, mode:0700)
      File.open(@vm.file('files.lock'), File::RDWR | File::CREAT, 0600) do |lock|
        raise Error, 'Another VM file mount operation is in progress.' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        yield
      end
    end
    def mount_unlocked
      unless mounted?
        @vm.start unless @vm.running?
        FileUtils.mkdir_p(@mount, mode:0700)
        raise Error, 'Mount folder must not be a symlink.' if File.symlink?(@mount)
        raise Error, "Mount folder is not empty: #{@mount}" unless Dir.children(@mount).empty?
        begin
          close_transport
          port = start_transport
          source = File.join(__dir__, 'mount.swift')
          helper = @vm.file('mount-native')
          digest = Digest::SHA256.file(source).hexdigest
          unless File.executable?(helper) && File.file?(@vm.file('mount-native.sha256')) && File.read(@vm.file('mount-native.sha256')) == digest
            AgentVM.run('/usr/bin/xcrun', 'swiftc', '-O', '-module-cache-path', @vm.file('swift-module-cache'), source, '-o', helper, timeout:120)
            AgentVM.write(@vm.file('mount-native.sha256'), digest)
          end
          AgentVM.run(helper, input:JSON.generate({user:@vm.config['user'], password:@vm.password, port:port, mount:@mount}), timeout:60)
        rescue StandardError
          # A failed native mount can still have created a mount. Do not strand
          # it by tearing down its transport while the filesystem is in use.
          AgentVM.run('/sbin/umount', @mount, timeout:30) if mounted?
          close_transport
          raise
        end
      end
    end

    def start_transport
      generation = SecureRandom.hex(16)
      owner = @vm.running_pid
      raise Error, 'VM is not running.' unless owner && owner > 0
      path = @vm.file('files-relay.json')
      File.unlink(path) if File.file?(path)
      AgentVM.write(@vm.file('files-launch.plist'), AgentVM.plist({
        'Label'=>@label,
        'ProgramArguments'=>['/usr/bin/ruby', @vm.file('runtime/lib/files-relay.rb'), @vm.state, owner.to_s, generation],
        'EnvironmentVariables'=>{'AGENT_VM_HOME'=>AgentVM.state_root, 'TART_HOME'=>ENV.fetch('TART_HOME', File.expand_path('~/.tart')),
                                'DO_NOT_TRACK'=>'1', 'OTEL_SDK_DISABLED'=>'true'},
        'RunAtLoad'=>true, 'KeepAlive'=>false, 'ExitTimeOut'=>15,
        'StandardOutPath'=>@vm.file('files-relay.log'), 'StandardErrorPath'=>@vm.file('files-relay.log')
      }))
      AgentVM.run('/bin/launchctl', 'bootstrap', @vm.domain, @vm.file('files-launch.plist'))
      port = nil
      @vm.wait_for(15, 'Opening private file transport') do
        next false unless File.file?(path)
        data = JSON.parse(File.read(path))
        next false unless data['generation'] == generation && data['owner'] == owner && @vm.running_pid == owner
        Process.kill(0, Integer(data['pid']))
        port = Integer(data['port'])
        raise Error, 'Invalid file relay port.' unless (1024..65535).cover?(port)
        true
      end
      port
    end

    def close_transport
      # Upgrades retire the previous SSH master as well as any stale relay job.
      close_legacy_tunnel
      job, status = Open3.capture2e('/bin/launchctl', 'print', "#{@vm.domain}/#{@label}")
      owner = status.success? ? job[/^\s*pid = (\d+)$/, 1].to_i : 0
      system('/bin/launchctl', 'bootout', "#{@vm.domain}/#{@label}", out:File::NULL, err:File::NULL)
      path = @vm.file('files-relay.json')
      if File.file?(path)
        # A stale PID may now belong to another program. Never signal it or wait
        # for it unless launchd confirmed it owned this exact service.
        data = JSON.parse(File.read(path))
        unless owner > 0 && data['pid'] == owner
          File.unlink(path)
          return
        end
        @vm.wait_for(15, 'Closing private file transport') do
          begin
            Process.kill(0, Integer(JSON.parse(File.read(path))['pid']))
            false
          rescue Errno::ESRCH, Errno::ENOENT
            true
          end
        end
        File.unlink(path) if File.file?(path)
      end
    end

    def close_legacy_tunnel
      return unless File.socket?(@socket)
      AgentVM.run(*@vm.ssh_args, '-S', @socket, '-O', 'exit', @vm.name, capture:true, timeout:10)
    rescue Error
      File.unlink(@socket) if File.socket?(@socket)
    end
    def unmount
      # A busy mount fails visibly; never force unmount while a file is in use.
      with_lock do
        AgentVM.run('/sbin/umount', @mount, timeout:30) if mounted?
        close_transport
      end
    end
  end
end
