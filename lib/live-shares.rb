require_relative 'runtime'
require_relative 'shared'
require_relative 'install'

module AgentVM
  class LiveShares
    KEYS = %w[sharing share guest_share read_only_share guest_read_only_share linked_share guest_linked_share linked_files share_read_only external_links share_python].freeze
    def initialize(vm); @vm = vm; end
    def marker; @vm.file('sharing-in-progress.json'); end
    def guest(action, config = nil)
      source = File.read(File.expand_path('../guest/share-transition.rb', __dir__))
      input = config ? JSON.generate(AgentVM.guest_config(config)) : ''
      @vm.root('/usr/bin/ruby', '-e', source, action, input:input, timeout:45)
    end
    def attach(config)
      rows = AgentVM.share_entries(config).map do |entry|
        {'tag'=>entry['tag'], 'path'=>entry['kind'] == 'macfuse' ? @vm.file('shared-view') : entry['host'], 'read_only'=>entry['read_only']}
      end
      Runtime.new(@vm).request('op'=>'shares-set', 'shares'=>rows)
    end
    def detach
      value = Runtime.new(@vm).request('op'=>'shares-set', 'shares'=>[])
      raise Error, 'The runtime did not detach its shares.' unless value['shares'] == []
    end
    def receipt
      saved = JSON.parse(File.read(@vm.file('access-launch.json'))) rescue {}
      config = saved.fetch('configuration', {}).merge(@vm.config.select { |key, _| KEYS.include?(key) })
      saved.merge!('pid'=>@vm.running_pid, 'runtime'=>'custom', 'shares'=>AgentVM.share_entries(@vm.config), 'configuration'=>config)
      AgentVM.json_write(@vm.file('access-launch.json'), saved)
    end
    def recover
      return unless File.file?(marker)
      old = JSON.parse(File.read(marker)).fetch('previous')
      if @vm.running?
        guest('pause')
        detach
        Shared.new(@vm).stop_host(detached:true)
      end
      # Roll back only this transaction's folder settings. A concurrent
      # network/media preference must not be silently restored to an old grant.
      KEYS.each { |key| old.key?(key) ? @vm.config[key] = old[key] : @vm.config.delete(key) }
      AgentVM.validate(@vm.config)
      @vm.save
      if @vm.running?
        shared = Shared.new(@vm)
        shared.prepare
        shared.owner(@vm.running_pid)
        attach(@vm.config)
        guest('apply', @vm.config)
        receipt
      end
      File.unlink(marker)
    end
    def change(config)
      return puts('Shared folders are already configured; no mounts changed.') if config == @vm.config
      runtime = Runtime.new(@vm).current
      unless runtime && runtime.fetch('features', []).include?('live-shares')
        raise Error, 'This running Tart cannot change folder attachments live. Stop it first, or select vm runtime custom for its next start. No session was interrupted.'
      end
      installer = Installer.new(config)
      installer.sharing_tools
      installer.sharing_directories(VM.new(config))
      @vm.with_lifecycle_lock do
        recover
        old = JSON.parse(JSON.generate(@vm.config))
        paused = false
        committed = false
        begin
          guest('pause')
          paused = true
          AgentVM.json_write(marker, {'previous'=>old})
          detach
          Shared.new(@vm).stop_host(detached:true)
          @vm.config.replace(config)
          @vm.save
          shared = Shared.new(@vm)
          shared.prepare
          shared.owner(@vm.running_pid)
          attach(@vm.config)
          guest('apply', @vm.config)
          receipt
          File.unlink(marker)
          committed = true
        ensure
          unless committed
            if File.file?(marker)
              recover
            elsif paused && @vm.running?
              guest('resume')
            end
          end
        end
      end
      puts 'Shared folders updated live; VM and SSH sessions kept. Busy files must be closed before changing their mount.'
    end
  end
end
