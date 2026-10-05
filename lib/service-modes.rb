require_relative 'core'

module AgentVM
  # A saved startup choice and an override for one Tart process are separate.
  # Changing the former must not start or stop a service in the current run.
  module ServiceModes
    def service_record(path)
      File.file?(path) ? JSON.parse(File.read(path)) : {}
    rescue JSON::ParserError, Errno::ENOENT
      {}
    end
    def requested?
      once = service_record(session_path)
      if once['owner'].is_a?(Integer) && once['owner'] > 0 && @vm.running_pid == once['owner']
        return once.fetch('enabled', true) # Older one-run grants were always on.
      end
      autostart?
    end
    def clear_session(owner:nil)
      return if owner && service_record(session_path)['owner'] != owner
      File.unlink(session_path) if File.file?(session_path)
    rescue Errno::ENOENT
      nil
    end
    # Call under the service's own lock.
    def select_mode(enabled, once:false)
      if once
        owner = @vm.running_pid
        raise Error, 'Start the VM first; --once applies only to its current run.' unless owner > 0
        AgentVM.json_write(session_path, {'owner'=>owner, 'enabled'=>enabled})
      else
        save_autostart(enabled)
        @vm.save
        clear_session
      end
    end
    def set_autostart(enabled)
      lock do
        current = requested?
        owner = @vm.running_pid
        AgentVM.json_write(session_path, {'owner'=>owner, 'enabled'=>current}) if owner > 0
        save_autostart(enabled)
        @vm.save
      end
    end
  end
end
