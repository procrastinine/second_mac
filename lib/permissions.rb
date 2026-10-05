require_relative 'core'
require_relative 'ui'

module AgentVM
  class Permissions
    def initialize(vm); @vm = vm; end
    def label; 'local.second-mac.' + @vm.name + '.permissions'; end
    def install_client
      return unless @vm.config['phase'] == 'ready'
      return if @vm.config['throwaway'] # Keep the client's saved version; only its per-boot token changes.
      # Existing installations receive the same headless-display correction
      # as finalize.rb on their next managed start, without a package update.
      if @vm.ui_available?
        power = @vm.ssh('/usr/bin/pmset', '-g', capture:true)
        @vm.root('/usr/bin/pmset', '-a', 'displaysleep', '0') unless power.match?(/^\s*displaysleep\s+0(?:\s|$)/)
      end
      sources = {'control-client.rb'=>File.read(File.join(__dir__, '..', 'guest/control-client.rb'), encoding:'UTF-8'),
                 'core.rb'=>File.read(File.join(__dir__, 'core.rb'), encoding:'UTF-8'),
                 'profile-plan.rb'=>File.read(File.join(__dir__, 'profile-plan.rb'), encoding:'UTF-8')}
      installer = File.read(File.join(__dir__, '..', 'guest/install-control.rb'), encoding:'UTF-8')
      @vm.root('/usr/bin/ruby', '-e', installer, input:JSON.generate('user'=>@vm.config.fetch('user'), 'sources'=>sources))
    end
    def direct(args, capture:false)
      # Execute the selected operation using existing system Ruby/SQLite over
      # the authenticated transport. No guest UI app, daemon or TCC bootstrap.
      source = File.read(File.join(__dir__, '..', 'guest', 'permissions.rb'))
      @vm.ssh('/usr/bin/sudo', '-k', '-S', '-p', '', '/usr/bin/ruby', '-e', source, '--', *args,
              input:@vm.password + "\n", capture:capture, timeout:30)
    end
    def change(action, app, names)
      raise Error, 'Choose an absolute guest app path and explicit permission names.' unless app && app.start_with?('/') && !names.empty?
      if SIP.new(@vm).state == 'off'
        direct([action, app, *names], capture:true)
      else
        require_relative 'permission-ui'
        workflow = PermissionUI.new(@vm)
        names.map { |name| workflow.grant(app, name, enabled:action == 'grant') }.join("\n")
      end
    end
    def start_watcher
      return unless @vm.config['permissions_auto'] && @vm.ui_available? && @vm.running?
      path = @vm.file('permission-watch.plist')
      AgentVM.write(path, AgentVM.plist('Label'=>label, 'ProgramArguments'=>[
        '/usr/bin/ruby', File.join(__dir__, 'cli.rb'), '--name', @vm.name, 'permissions', 'watch', @vm.running_pid.to_s],
        'EnvironmentVariables'=>{'AGENT_VM_HOME'=>AgentVM.state_root, 'TART_HOME'=>ENV.fetch('TART_HOME', File.join(Dir.home,'.tart')), 'LANG'=>'en_US.UTF-8', 'LC_ALL'=>'en_US.UTF-8'},
        'RunAtLoad'=>true, 'KeepAlive'=>false, 'StandardOutPath'=>@vm.file('permission-watch.log'),
        'StandardErrorPath'=>@vm.file('permission-watch.log')))
      stop_watcher
      # bootout can return while launchd is still releasing the old job.
      # A repeated opt-in should not fail spuriously during that short interval.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      begin
        AgentVM.run('/bin/launchctl', 'bootstrap', @vm.domain, path, capture:true)
      rescue Error
        raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.2
        retry
      end
    end
    def stop_watcher
      system('/bin/launchctl', 'bootout', @vm.domain + '/' + label, out:File::NULL, err:File::NULL)
    end
    def watch(owner)
      raise Error, 'Invalid VM owner process.' unless owner.match?(/\A[1-9]\d*\z/)
      ui = Desktop.new(@vm)
      previous = nil
      while @vm.running_pid == owner.to_i
        begin
          approved = File.open(@vm.file('permission-ui.lock'), File::RDWR|File::CREAT, 0600) do |lock|
            lock.flock(File::LOCK_EX|File::LOCK_NB) && ui.approve_once
          end
          puts 'Approved a guest permission dialog.' if approved
          # SIP-off users also get deterministic grants for recorded requests,
          # including categories that send the user to System Settings.
          output = direct(['approve-recorded'], capture:true)
          puts output unless output.empty?
          previous = nil
        rescue Error => error
          warn error.message unless previous == error.message
          previous = error.message
        end
        sleep 5
      end
    end
    def command(args)
      action = args.shift || 'status'
      if %w[help --help -h].include?(action)
        puts 'vm permissions check|grant|revoke /guest/path/App.app PERMISSION...'
        puts 'SIP on: accessibility, full-disk, input-monitoring, screen-recording use guest Settings; camera/microphone need an initial app request.'
        puts 'Other consent dialogs: vm permissions auto on|off. Direct database grants require explicitly disabling guest SIP from the host.'
        puts 'vm permissions extension camera|network|filesystem EXACT_APP_LABEL'
        puts 'Examples: extension camera OBS; extension network LuLu; extension filesystem "macFUSE (local)"'
        puts 'All automation is deterministic and local. No LLM, cloud inference, or host desktop control.'
        return
      end
      if action == 'watch'
        return watch(args.fetch(0))
      elsif action == 'auto'
        mode = args.shift || 'status'
        case mode
        when 'status'
          puts "Automatic guest approval: #{@vm.config['permissions_auto'] ? 'enabled' : 'disabled'}"
          puts "VM: #{@vm.running? ? 'running' : 'stopped; no approval process is needed'}"
        when 'off'
          @vm.config['permissions_auto'] = false; @vm.save; stop_watcher
          puts 'Automatic approval disabled. Existing guest grants are retained.'
        when 'on'
          raise Error, 'Usage: vm permissions auto on [--restart] [--disable-sip]' unless (args - %w[--restart --disable-sip]).empty?
          Desktop.new(@vm).enable(restart:args.include?('--restart') || args.include?('--disable-sip'))
          SIP.new(@vm).command(['off']) if args.include?('--disable-sip')
          @vm.config['permissions_auto'] = true; @vm.save; start_watcher
          puts 'Automatic guest permission approval enabled. It stops with this VM and resumes on its next start.'
        else raise Error, 'Usage: vm permissions auto on|off|status'
        end
        return
      end
      raise Error, 'Usage: vm permissions status|check|grant|revoke|extension|auto|help' unless %w[status check grant revoke extension].include?(action)
      @vm.start unless @vm.running?
      if %w[grant revoke].include?(action)
        puts change(action, args.shift, args)
      elsif action == 'extension'
        raise Error, 'Usage: vm permissions extension camera|network|filesystem APP_LABEL' unless args.length == 2
        require_relative 'permission-ui'
        puts PermissionUI.new(@vm).extension(*args)
      else
        direct([action, *args])
      end
      puts "Automatic guest approval: #{@vm.config['permissions_auto'] ? 'enabled' : 'disabled'}" if action == 'status'
    end
  end
end
