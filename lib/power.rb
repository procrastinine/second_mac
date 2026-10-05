require_relative 'core'

module AgentVM
  class Power
    def initialize(vm); @vm = vm; end
    def reboot
      @vm.start unless @vm.running?
      @vm.with_lifecycle_lock do
        original_pid = @vm.running_pid
        original_boot = @vm.ssh('/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid', capture:true).strip
        begin
          @vm.root('/sbin/shutdown', '-r', 'now', timeout:15)
        rescue Error
          # Shutdown can close the transport before returning. Observe a new
          # guest boot; never retry a possibly successful reboot request.
        end
        @vm.wait_for(240, 'Waiting for guest macOS reboot') do
          @vm.launch_unlocked if !@vm.running?
          observed = @vm.ssh('/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid', capture:true, timeout:5).strip
          observed.match?(/\A[0-9A-F-]{36}\z/i) && observed != original_boot
        end
        if @vm.running_pid == original_pid
          puts 'Guest macOS rebooted; the same Tart process was kept. Guest processes and SSH connections restarted.'
        else
          puts 'Guest macOS rebooted; its runtime also exited and was relaunched.'
        end
      end
      @vm.start
    end
  end
end
