require_relative 'core'
require 'io/console'

module AgentVM
  # Account provisioning is a first-boot capability, not a requirement for
  # running an already configured guest or for the rest of the installer.
  class FirstBoot
    def initialize(vm)
      @vm = vm
    end

    def prepare
      return @vm.config['setup_method'] if @vm.config['setup_method']
      host = AgentVM.run('/usr/bin/sw_vers', '-productVersion', capture:true).split('.').first.to_i
      guest = @vm.config.dig('restore_image', 'version').to_s.split('.').first.to_i
      # Installations begun before setup_method existed used native provisioning.
      # Never replace their account/password selection during a retry.
      legacy = @vm.config['phase'] == 'bootstrap'
      native = @vm.config['setup'] != 'manual' && host >= 27 && (guest >= 27 || legacy)
      if native
        runner = @vm.needs_custom_tart? ? @vm.config.fetch('ui_tart', @vm.tart) : @vm.tart
        native = AgentVM.run(runner, 'run', '--help', capture:true).include?('--provisioning-opts')
      end
      if legacy && !native
        raise Error, 'This installation already began automatic account setup. Resume it with macOS 27 and a Tart build with guest provisioning support; its disk and credentials are retained.'
      end
      @vm.config['setup_method'] = native ? 'native' : 'manual'
      @vm.save
      @vm.config['setup_method']
    end

    def manual?
      @vm.config['setup_method'] == 'manual'
    end

    def awaiting_account?
      manual? && !@vm.config['manual_password_confirmed']
    end

    def launch
      prepare
      @vm.launch(graphics:awaiting_account? ? true : nil) unless @vm.running?
      return unless awaiting_account?
      # A retry may find a still-running but hidden Setup Assistant window.
      require_relative 'gui'
      window = GUI.new(@vm)
      begin
        AgentVM.run(window.helper, @vm.running_pid.to_s, 'show', capture:true, timeout:15) if window.active?
      rescue Error
        warn 'Could not bring the starting guest window forward. Open Tart from the Dock to complete Setup Assistant.'
      end
      puts "\nComplete Setup Assistant in the guest window (one time):"
      puts "  Create the account with account name #{@vm.config['user']} and a password of your choice."
      puts '  Skip migration and Apple Account sign-in; decline analytics, Siri and Apple Intelligence.'
      puts '  Open System Settings > General > Sharing and enable Remote Login for this account.'
      puts 'Then return to this terminal. The installer will ask for that guest password and continue automatically.'
      puts 'The host clipboard remains private. If interrupted, rerun the same install command to resume this disk.'
    end

    def password_from_console
      console = IO.console
      raise Error, 'Guided setup needs a terminal to read the guest password securely. Rerun the same install command in Terminal; the guest is retained.' unless console
      password = console.getpass("Password chosen for guest account #{@vm.config['user']}: ")
      raise Error, 'A nonempty guest password without control characters or surrounding whitespace is required.' if
        password.empty? || password != password.strip || password.match?(/[\x00-\x1f\x7f]/)
      password
    rescue EOFError
      raise Error, 'No guest password was entered. Rerun the installer in Terminal to resume.'
    end

    def authenticate(ip, port)
      if awaiting_account?
        # This records the password the user has already chosen in macOS; it
        # does not reset a guest account. Never expose it in argv or logs.
        AgentVM.write(@vm.file('admin-password'), password_from_console + "\n")
      end
      puts AgentVM.run('/usr/bin/expect', File.join(__dir__, 'bootstrap.exp'), @vm.state, @vm.config['user'], ip, port.to_s, capture:true, timeout:90)
      if manual? && !@vm.config['manual_password_confirmed']
        @vm.config['manual_password_confirmed'] = true
        @vm.save
      end
    rescue Error => error
      if manual? && error.message.include?('rejected the bootstrap password')
        @vm.config.delete('manual_password_confirmed')
        @vm.save
        raise Error, 'The guest rejected the password. Confirm the account name in Setup Assistant and rerun the installer to enter its password again.'
      end
      raise
    end
  end
end
