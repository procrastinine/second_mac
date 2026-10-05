require_relative 'runtime'
require_relative 'live-shares'

module AgentVM
  # A memory checkpoint is coupled to its disk and original virtual hardware.
  # Never discard it or fall back to a cold boot after a restore failure.
  class Suspend
    def initialize(vm); @vm = vm; end
    def path; File.join(@vm.tart_directory, 'state.vzvmsave'); end
    def marker; @vm.file('suspend.json'); end
    def retained_path; path + '.restore-guard'; end
    def suspended?; File.file?(path); end
    def record; JSON.parse(File.read(marker)); end
    def boot_id; @vm.ssh('/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid', capture:true).strip; end
    def supported?
      return false unless @vm.running?
      active = Runtime.new(@vm).current
      active && (active.fetch('features', []).include?('save-restore') ||
        (active['runtime'] == 'standard' && active['suspendable'] == true && active['stable_devices'] == true))
    rescue Error
      false
    end
    def finish_stop
      raise Error, 'Saved memory is missing; refusing to terminate Tart.' unless suspended?
      raise Error, 'Memory saving has not completed; current work and checkpoint were kept.' unless record['status'] == 'saved'
      AgentVM.run(@vm.tart, 'stop', @vm.name, '--timeout', '0') if @vm.running?
      @vm.wait_for(90, 'Waiting for saved VM process exit') { !@vm.running? }
      @vm.stop_host_services
      Shared.new(@vm).stop
      File.chmod(0600, path)
      @vm.exclude_backup(path)
      puts 'Suspended: CPU/RAM released; guest processes and tmux are saved. Use vm resume. SSH connections must reconnect.'
    end
    def save
      @vm.with_lifecycle_lock do
        if suspended?
          raise Error, 'Unmanaged saved state; use the original Tart launch configuration to resume it.' unless File.file?(marker)
          recover_completion
          return finish_stop
        end
        if File.file?(marker)
          recover_completion
          return finish_stop if suspended?
          raise Error, 'A memory checkpoint is still in progress or failed. Its files were kept; inspect vm logs before retrying.'
        end
        raise Error, 'Start the VM before suspending it.' unless @vm.running?
        raise Error, 'This running Tart lacks managed save/restore support. A new managed start is needed; current work was kept.' unless supported?
        active = Runtime.new(@vm).current
        Runtime.new(@vm).request('op'=>'save-check') if active['runtime'] == 'custom'
        launch = JSON.parse(File.read(@vm.file('access-launch.json')))
        raise Error, 'No matching launch configuration; current work was kept.' unless launch['pid'] == @vm.running_pid && launch['configuration']
        config = launch.fetch('configuration').merge('runtime_mode'=>active['runtime'])
        config['ui_enabled'] = active['ui_enabled'] if active.key?('ui_enabled')
        binary = config['runtime_mode'] == 'custom' ? config.fetch('ui_tart') : config.fetch('tart')
        binary = File.realpath(binary)
        config[active['runtime'] == 'custom' ? 'ui_tart' : 'tart'] = binary
        state = {'status'=>'saving', 'configuration'=>config, 'binary'=>binary, 'binary_sha256'=>Digest::SHA256.file(binary).hexdigest,
          'hardware_sha256'=>Digest::SHA256.file(File.join(@vm.tart_directory, 'config.json')).hexdigest,
          'boot_id'=>boot_id, 'owner'=>@vm.running_pid, 'shares_paused'=>false,
          'stdout_offset'=>File.file?(@vm.file('stdout.log')) ? File.size(@vm.file('stdout.log')) : 0}
        quiesced = false
        begin
          unless AgentVM.share_entries(@vm.config).empty?
            LiveShares.new(@vm).guest('pause')
            quiesced = state['shares_paused'] = true
          end
          @vm.ssh('/bin/sync', capture:true)
          @vm.stop_host_services
          AgentVM.json_write(marker, state)
          if active['runtime'] == 'custom'
            value = Runtime.new(@vm).request({'op'=>'save-state'}, timeout:180)
            raise Error, 'Tart did not confirm a saved state.' unless value['saved']
          else
            AgentVM.run(@vm.tart, 'suspend', @vm.name)
            @vm.wait_for(180, 'Saving guest memory') { !@vm.running? }
            raise Error, 'Tart did not confirm successful memory saving. Check vm logs; no cold boot will be attempted.' unless standard_completed?(state)
          end
          state['status'] = 'saved'
          AgentVM.json_write(marker, state)
          finish_stop
        rescue StandardError
          # Preserve any completed snapshot, even if a later cleanup failed.
          # Retrying vm suspend then finishes the stopped-process handoff.
          active = Runtime.new(@vm).current rescue nil
          incomplete = File.file?(path+'.saving') || (active && (active['saving'] || active['state'] == 2))
          unless suspended? || incomplete || !@vm.running?
            if @vm.running?
              LiveShares.new(@vm).guest('resume') if quiesced
              require_relative 'network'
              Network.new(@vm).start_watcher
              require_relative 'ports'
              Ports.new(@vm).start_all
              @vm.start_services
            end
            File.unlink(marker) if File.file?(marker)
          end
          raise
        end
      end
    end
    def standard_completed?(saved)
      data = File.binread(@vm.file('stdout.log'), nil, saved.fetch('stdout_offset', 0))
      data.include?('snapshot created successfully! shutting down the VM...')
    rescue SystemCallError
      false
    end
    def recover_completion
      saved = record
      return if saved['status'] == 'saved'
      if suspended? && saved.dig('configuration', 'runtime_mode') == 'custom'
        # Custom Tart atomically renames only a fully written memory checkpoint.
        active = Runtime.new(@vm).current if @vm.running?
        raise Error, 'Memory saving is still in progress.' if active && active['saving']
      elsif suspended? && !@vm.running? && standard_completed?(saved)
        # Upstream writes directly to the final path; existence is insufficient.
      else
        return
      end
      saved['status'] = 'saved'
      AgentVM.json_write(marker, saved)
    end
    def resume_configuration
      raise Error, 'Saved memory has no managed launch record; refusing to guess its hardware. Use its original runtime to resume.' unless File.file?(marker)
      recover_completion
      saved = record
      raise Error, 'Memory saving was not confirmed complete. Inspect vm logs or retry vm suspend before resuming.' unless saved['status'] == 'saved'
      config = AgentVM.validate(saved.fetch('configuration'))
      raise Error, 'VM hardware changed while suspended; restore its saved configuration before resuming.' unless
        Digest::SHA256.file(File.join(@vm.tart_directory, 'config.json')).hexdigest == saved['hardware_sha256']
      raise Error, 'The original Tart executable is missing or changed. Restore that executable before resuming.' unless
        File.executable?(saved['binary']) && Digest::SHA256.file(saved['binary']).hexdigest == saved['binary_sha256']
      raise Error, 'Host shares changed while suspended. Restore the saved sharing settings before resuming.' unless
        AgentVM.share_entries(config) == AgentVM.share_entries(@vm.config)
      if config['microphone'] && !@vm.config['microphone']
        raise Error, 'Saved memory includes microphone input. Resume with that setting enabled, then shut down cleanly to detach it.'
      end
      # Network policy and host delegation are current permissions, not guest
      # hardware. Never restore a revoked one-boot delegation grant.
      %w[network_mode network_resume_mode ui_enabled guest_control permissions_auto camera_obs credential_relays credential_relay_cleanup].each do |key|
        config[key] = @vm.config[key] if @vm.config.key?(key)
      end
      config
    end
    def protect_standard_restore
      return unless record.dig('configuration', 'runtime_mode') == 'standard'
      # Upstream unlinks the state between restore() and resume(). A hard link
      # preserves the same bytes, without another local copy, until SSH verifies
      # the original guest boot. An interrupted restore never erases the only
      # checkpoint; recovery is deliberately explicit if the outcome is unclear.
      File.link(path, retained_path) unless File.exist?(retained_path)
    end
    def finish_resume
      return unless File.file?(marker) && !suspended?
      saved = record
      raise Error, 'Guest boot identity differs from saved memory; inspect the saved-state operation before continuing.' unless boot_id == saved.fetch('boot_id')
      LiveShares.new(@vm).guest('resume') if saved['shares_paused']
      File.unlink(retained_path) if File.file?(retained_path)
      File.unlink(marker)
      puts 'Resumed the same guest boot: processes and tmux kept. Reconnect shells with vm ssh or vm tmux.'
    end
    def discard
      @vm.with_lifecycle_lock do
        raise Error, 'Stop the Tart process before discarding saved memory; a running guest was kept.' if @vm.running?
        raise Error, 'No managed checkpoint record. Use the original Tart configuration for this saved state.' unless File.file?(marker)
        # Explicit power-loss recovery. The disk is retained; never do this as
        # an automatic fallback after a restore error or host software update.
        paths = [path, path + '.saving', retained_path]
        raise Error, 'Unsafe checkpoint file; no files removed.' if paths.any? { |item| File.symlink?(item) || (File.exist?(item) && !File.file?(item)) }
        paths.each { |item| File.unlink(item) if File.file?(item) }
        File.unlink(marker)
        puts 'Saved memory discarded. Unsaved work and guest processes are lost; the existing disk is kept. vm start will boot macOS anew.'
      end
    end
    def command(args)
      if args == ['discard', '--yes']
        discard
      elsif args.empty?
        save
      else
        raise Error, 'Usage: vm suspend | vm resume | vm suspend discard --yes (lose saved memory, keep the disk)'
      end
    end
  end
end
