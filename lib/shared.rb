require_relative 'core'

module AgentVM
  class Shared
    def initialize(vm)
      @vm = vm
      @label = "local.agent-vm.#{vm.name}.share"
    end
    def mountpoint; @vm.file('shared-view'); end
    def mounted?
      AgentVM.run('/sbin/mount', capture:true).lines.any? { |line| line.include?(" on #{mountpoint} (macfuse,") }
    end
    def prepare
      return if @vm.config['sharing'] == 'none'
      entries = AgentVM.shares(@vm.config)
      return entries.first['host'] unless entries.any? { |entry| entry['kind'] == 'macfuse' }
      python = @vm.config['share_python']
      raise Error, 'Host sharing dependencies missing; run vm apply.' unless python && File.executable?(python)
      raise Error, 'Install and enable macFUSE on the host, then restart macOS before starting the VM.' unless File.file?('/usr/local/lib/libfuse.2.dylib')
      stop_host if mounted?
      FileUtils.mkdir_p(mountpoint, mode:0700)
      # A failed mount must never silently expose an ordinary writable directory.
      raise Error, 'The private share mountpoint must be empty.' unless Dir.empty?(mountpoint)
      plist = @vm.file('share-launch.plist')
      @generation = SecureRandom.hex(16)
      AgentVM.json_write(@vm.file('share-owner.json'), {'generation'=>@generation, 'pid'=>0})
      AgentVM.write(plist, AgentVM.plist({
        'Label'=>@label,
        'ProgramArguments'=>[python, @vm.file('runtime/lib/projection-server.py'), @vm.state, @generation],
        'RunAtLoad'=>true, 'KeepAlive'=>false,
        # VirtioFS retains backing handles for cached guest inodes even after
        # applications close their files. launchd's usual 256-descriptor soft
        # limit is too small for ordinary project trees. This is per-service;
        # it does not change the host's global limit or reserve descriptors.
        'SoftResourceLimits'=>{'NumberOfFiles'=>65_536},
        'EnvironmentVariables'=>{'DO_NOT_TRACK'=>'1', 'PYTHONDONTWRITEBYTECODE'=>'1'},
        'StandardOutPath'=>@vm.file('share-server.log'), 'StandardErrorPath'=>@vm.file('share-server.log')
      }))
      system('/bin/launchctl', 'bootout', "#{@vm.domain}/#{@label}", out:File::NULL, err:File::NULL)
      AgentVM.run('/bin/launchctl', 'bootstrap', @vm.domain, plist)
      @vm.wait_for(20, 'Preparing shared filesystem') do
        mounted? && File.directory?(mountpoint) && Dir.entries(mountpoint).include?('.')
      end
      mountpoint
    end
    def owner(pid)
      AgentVM.json_write(@vm.file('share-owner.json'), {'generation'=>@generation, 'pid'=>pid}) if AgentVM.share_entries(@vm.config).any? { |entry| entry['kind'] == 'macfuse' }
      AgentVM.json_write(@vm.file('vm-process.json'), {'pid'=>pid})
    end
    def start
      return if @vm.config['sharing'] == 'none'
      raise Error, 'Sharing requires a running VM.' unless @vm.running?
      projected = AgentVM.share_entries(@vm.config).any? { |entry| entry['kind'] == 'macfuse' }
      raise Error, 'The running VM has no scoped share attached; shut it down and start it again.' if projected && !mounted?
      @vm.root('/usr/bin/ruby', '/usr/local/libexec/agent-vm/mount-share.rb', timeout:30)
    end
    def stop_host(detached:false)
      return if @vm.config['sharing'] == 'none'
      raise Error, 'Shut down the VM before detaching its shared filesystem.' if @vm.running? && !detached
      if mounted?
        begin
          AgentVM.run('/sbin/umount', '-f', mountpoint, capture:true, timeout:15)
        rescue Error
          # The owner watcher can finish unmounting between the check and call.
          raise if mounted?
        end
      end
      system('/bin/launchctl', 'bootout', "#{@vm.domain}/#{@label}", out:File::NULL, err:File::NULL)
    end
    alias stop stop_host
  end
end
