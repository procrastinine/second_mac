require_relative 'profiles'

module AgentVM
  class Agents
    NAMES = %w[pi codex claude].freeze
    def initialize(vm); @vm = vm; end
    def command(args)
      action = args.shift || 'list'
      case action
      when 'list'
        raise Error, 'Usage: vm agents list' unless args.empty?
        puts 'Selected agents: ' + (@vm.config['agents'].empty? ? 'none' : @vm.config['agents'].join(', '))
        puts 'Install or update only the named agents: vm agents add pi codex claude'
      when 'add'
        add(args)
      else
        raise Error, 'Usage: vm agents [list | add pi codex claude]'
      end
    end
    def add(names)
      raise Error, 'Choose one or more of pi, codex, claude.' if names.empty? || !(names - NAMES).empty?
      names = names.uniq
      if names.include?('pi') && !@vm.config['agents'].include?('pi')
        require_relative 'credentials'
        requested = @vm.config['credential_relays'].include?('openrouter')
        unless requested && HostCredentials.available?
          accepted = requested ? HostCredentials.prompt(optional:true) : HostCredentials.offer_pi
          Credentials.new(@vm).set(accepted ? 'on' : 'off') if requested || accepted
        end
      end
      Profiles.new(@vm).add(['web']) unless @vm.config['profiles'].include?('web')
      @vm.start unless @vm.running?
      @vm.with_lifecycle_lock do
        original = @vm.config['agents'].dup
        destination = @vm.home + '/.cache/agent-vm-setup'
        begin
          @vm.config['agents'] = (original + names).uniq
          Installer.new(@vm.config, integrations:false).stage(@vm, bootstrap:false)
          @vm.ssh('/bin/bash', destination + '/guest/install-agents.sh', *names, timeout:1200)
          @vm.save
          require_relative 'credentials'
          Credentials.new(@vm).start
          puts 'Agents ready: ' + names.join(', ') + '. Open them with vm pi, vm codex or vm claude.'
        rescue StandardError
          @vm.config['agents'] = original
          @vm.save
          # Retain partially installed packages for a retry, without recording
          # the requested agents as ready or changing unrelated agents.
          @vm.ssh('/usr/bin/tee', @vm.home + '/.config/agent-vm.json',
                  input:JSON.generate(AgentVM.guest_config(@vm.config)), capture:true) rescue nil
          raise
        ensure
          @vm.ssh('/bin/rm', '-rf', destination, capture:true) rescue nil
        end
      end
    end
  end
end
