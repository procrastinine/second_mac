require_relative 'core'
require_relative 'install'

module AgentVM
  class Profiles
    def initialize(vm)
      @vm = vm
    end
    def command(args)
      action = args.shift || 'list'
      case action
      when 'list'
        raise Error, 'Usage: vm profiles [list | add PROFILE... | install PROFILE...]' unless args.empty?
        ProfilePlan::DESCRIPTIONS.each do |name, description|
          puts "#{@vm.config['profiles'].include?(name) ? '*' : ' '} #{name}: #{description}"
        end
        puts '* selected; vm profiles add full selects every tool profile. Agents remain optional.'
      when 'add', 'install'
        raise Error, 'Choose base, web, science, documents, media, build, latex or full.' if args.empty?
        add(args.flat_map { |arg| arg.split(',') }, ensure_selected: action == 'install')
      else
        raise Error, 'Usage: vm profiles [list | add PROFILE... | install PROFILE...]'
      end
    end
    def add(names, ensure_selected: false)
      selected = ProfilePlan.expand(@vm.config['profiles'] + names, @vm.config['agents'])
      added = selected - @vm.config['profiles']
      return puts('Those profiles are already selected. Use vm profiles install PROFILE to fill missing packages; use guest package managers for upgrades.') if added.empty? && !ensure_selected
      install = ensure_selected ? ProfilePlan.expand(names, @vm.config['agents']) : added
      @vm.start unless @vm.running?
      @vm.with_lifecycle_lock do
        original = @vm.config['profiles'].dup
        destination = @vm.home + '/.cache/agent-vm-setup'
        begin
          @vm.config['profiles'] = selected
          installer = Installer.new(@vm.config, integrations:false)
          installer.stage(@vm, bootstrap:false)
          @vm.ssh('/bin/bash', destination + '/guest/install-tools.sh', *install, timeout:7200)
          @vm.ssh('/usr/bin/ruby', @vm.home + '/.local/share/agent-vm/doctor.rb', timeout:60)
          installer.collect_versions(@vm)
          @vm.save
          puts 'Tool profiles ready: ' + install.join(', ')
        rescue StandardError
          @vm.config['profiles'] = original
          @vm.save
          # Partially installed packages are harmless and remain for a retry.
          @vm.ssh('/usr/bin/tee', @vm.home + '/.config/agent-vm.json', input:JSON.generate(AgentVM.guest_config(@vm.config)), capture:true) rescue nil
          raise
        ensure
          @vm.ssh('/bin/rm', '-rf', destination, capture:true) rescue nil
        end
      end
    rescue ArgumentError => error
      raise Error, error.message
    end
  end
end
