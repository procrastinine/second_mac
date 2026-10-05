require_relative 'install'
require 'optparse'

module AgentVM
  class ShareSettings
    def initialize(vm)
      @vm = vm
    end

    def command(argv)
      return puts(JSON.pretty_generate(AgentVM.shares(@vm.config))) if argv.empty?
      args = argv.dup
      raise Error, 'Usage: vm shares [configure --sharing MODE --share PATH ...]' unless args.shift == 'configure'
      changes = {}
      parser = OptionParser.new do |o|
        o.banner = 'Usage: vm shares configure [options] (live with current custom Tart; otherwise stop first)'
        %w[sharing share guest-share read-only-share guest-read-only-share linked-share guest-linked-share].each do |key|
          o.on("--#{key} VALUE") { |value| changes[key.tr('-', '_')] = value }
        end
        o.on('--[no-]share-read-only') { |value| changes['share_read_only'] = value }
        o.on('--[no-]linked-files', 'Include or remove the optional hybrid linked folder') { |value| changes['linked_files'] = value }
        o.on('--[no-]external-links') { |value| changes['external_links'] = value }
        o.on('-h', '--help') { puts o; return }
      end
      parser.parse!(args)
      raise Error, 'Provide sharing options; see vm shares configure --help.' if changes.empty? || !args.empty?
      raise Error, 'Throwaways do not accept host shares.' if @vm.config['throwaway']
      raise Error, 'Resume before changing shared folders; saved memory retains its current attachments.' if @vm.suspended?
      config = AgentVM.validate(@vm.config.merge(changes))
      if @vm.running?
        require_relative 'live-shares'
        LiveShares.new(@vm).change(config)
        return puts JSON.pretty_generate(AgentVM.shares(@vm.config))
      end
      installer = Installer.new(config)
      @vm.with_lifecycle_lock do
        raise Error, 'Stop the VM before changing attached folders: vm stop.' if @vm.running?
        installer.sharing_directories(VM.new(config))
        AgentVM.write(@vm.file('config.before-sharing.json'), JSON.pretty_generate(@vm.config) + "\n")
        @vm.config.replace(config)
        @vm.save
      end
      puts 'Applying sharing configuration; existing host files are not moved. The VM will return to stopped afterward.'
      begin
        Installer.new(@vm.config).apply_configuration(@vm)
      ensure
        @vm.stop if @vm.running?
      end
      puts JSON.pretty_generate(AgentVM.shares(@vm.config))
    rescue OptionParser::ParseError => error
      raise Error, error.message
    end
  end
end
