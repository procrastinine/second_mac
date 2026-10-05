require_relative 'disk-files'
require_relative 'restore-image'
require 'time'

module AgentVM
  class Images
    def self.root; File.join(AgentVM.state_root, 'base-images'); end
    def self.list
      caches = Dir.glob(File.join(root, '*', 'manifest.json')).sort
      puts 'Pristine OS caches (automatically reusable):'
      puts '  none yet; the next fresh installation saves one before first boot' if caches.empty?
      caches.each do |path|
        data = JSON.parse(File.read(path))
        build = data['restore_image'] && "macOS #{data['restore_image']['version']} (#{data['restore_image']['build']})"
        puts "  #{File.basename(File.dirname(path))}: #{build || 'OS build not recorded'}, #{data['created_at']}, #{data['disk_gb']} GB, host macOS #{data['host_major']}"
      end
      puts 'Managed populated VMs (explicit --from-vm NAME copies their guest data and credentials):'
      managed = Dir.glob(File.join(AgentVM.state_root, '*', 'config.json'))
      managed.each do |path|
        data = JSON.parse(File.read(path))
        next unless data['phase'] == 'ready'
        puts "  #{data['name']} (guest account #{data['user']})"
      end
      puts 'Other Tart images (require deliberate import/setup; never chosen automatically):'
      tart_root = ENV.fetch('TART_HOME', File.join(Dir.home, '.tart'))
      names = managed.map { |path| File.basename(File.dirname(path)) }
      Dir.glob(File.join(tart_root, 'vms', '*', 'disk.img')).each do |path|
        name = File.basename(File.dirname(path))
        puts '  ' + name unless names.include?(name)
      end
      puts 'A local Apple restore file can also be selected with --ipsw /path/to/restore.ipsw.'
    end

    def initialize(vm)
      @vm = vm
    end
    def host_major
      AgentVM.run('/usr/bin/sw_vers', '-productVersion', capture:true).split('.').first.to_i
    end
    def restore_image
      latest = @vm.config['ipsw'] == 'latest'
      return unless latest || !@vm.config['ipsw'].start_with?('https://')
      unless @vm.config['restore_image']
        image = latest ? RestoreImage.latest : RestoreImage.local(@vm.config['ipsw'])
        @vm.config['restore_image'] = image
        @vm.save # Retries keep this selection, including partially downloaded IPSWs.
        puts "#{latest ? "Apple's latest compatible restore image" : 'Local restore image'}: macOS #{image['version']} (#{image['build']})."
      end
      RestoreImage.validate(@vm.config['restore_image'], local:!latest)
    end
    def restore_source
      image = restore_image
      @vm.config['ipsw'] == 'latest' ? image.fetch('url') : @vm.config.fetch('ipsw')
    end
    def metadata
      {'format'=>2, 'pristine'=>true, 'created_at'=>Time.now.utc.iso8601,
       'host_major'=>host_major, 'ipsw'=>@vm.config['ipsw'], 'disk_gb'=>@vm.config['disk_gb'], 'restore_image'=>restore_image}
    end
    def reusable
      return nil if @vm.config['fresh']
      expected = metadata
      Dir.glob(File.join(self.class.root, '*', 'manifest.json')).sort.reverse.find do |path|
        next false if File.symlink?(path) || File.symlink?(File.dirname(path))
        data = JSON.parse(File.read(path))
        next false unless data.is_a?(Hash) && [1, 2].include?(data['format']) && data['pristine'] == true &&
          %w[host_major ipsw disk_gb].all? { |key| data[key] == expected[key] }
        # A selector named "latest" is not evidence of the installed OS build.
        # Legacy/older bases stay available on disk but cannot silently win.
        !expected['restore_image'] || (data['restore_image'].is_a?(Hash) &&
          %w[version build].all? { |key| data['restore_image'][key] == expected['restore_image'][key] })
      rescue JSON::ParserError
        false
      end
    end
    def copy_image(source, destination, clone_only: false)
      raise Error, 'Destination VM already exists.' if File.exist?(destination) || File.symlink?(destination)
      temporary = destination + '.partial-' + SecureRandom.hex(6)
      FileUtils.mkdir_p(temporary, mode:0700)
      DiskFiles::NAMES.each { |name| DiskFiles.copy(File.join(source, name), File.join(temporary, name), clone_only:clone_only) }
      yield if block_given?
      File.rename(temporary, destination)
    ensure
      FileUtils.remove_entry_secure(temporary) if temporary && File.directory?(temporary)
    end
    def randomize
      AgentVM.run(@vm.tart, 'set', @vm.name, '--random-mac', '--random-serial')
    end
    def reuse
      manifest = reusable
      return false unless manifest
      directory = File.dirname(manifest)
      data = JSON.parse(File.read(manifest))
      puts "Verifying local pristine image saved #{data['created_at']} (no macOS download/install)."
      raise Error, 'Cached image checksum mismatch; use --fresh to create a new image.' unless DiskFiles.inventory(directory) == data['files']
      copy_image(directory, @vm.tart_directory)
      randomize
      puts 'Reused the matching local OS image. vm update --macos checks for later Apple updates.'
      true
    end
    def cache
      raise Error, 'Only the installer can cache an unbooted image before provisioning.' unless @vm.config['phase'] == 'creating'
      destination = File.join(self.class.root, Time.now.utc.strftime('%Y%m%dT%H%M%S') + '-' + SecureRandom.hex(4))
      data = metadata
      @vm.with_lifecycle_lock do
        DiskFiles.with_lock(@vm.tart_directory) { copy_image(@vm.tart_directory, destination) }
      end
      data['files'] = DiskFiles.inventory(destination)
      AgentVM.json_write(File.join(destination, 'manifest.json'), data)
      @vm.exclude_backup(File.join(destination, 'disk.img'))
      puts 'Saved a pristine local OS image before first boot for future installations.'
    end
    def clone_managed(name)
      source = VM.load(name)
      raise Error, 'Source must be a completed managed VM.' unless source.config['phase'] == 'ready'
      raise Error, 'Source VM has an interrupted restore; recover it before cloning.' if File.exist?(source.file('restore-in-progress.json'))
      raise Error, 'Cloning keeps the source guest username; use a pristine installation for a different account.' unless source.config['user'] == @vm.config['user']
      source.with_lifecycle_lock do
        DiskFiles.with_lock(source.tart_directory) do
          copy_image(source.tart_directory, @vm.tart_directory) do
            %w[admin-password id_ed25519 id_ed25519.pub known-hosts].each do |file|
              content = File.binread(source.file(file))
              content = @vm.name + ' ' + content.split[1,2].join(' ') + "\n" if file == 'known-hosts'
              AgentVM.write(@vm.file(file), content)
            end
          end
        end
      end
      puts 'Copied the selected guest disk and credentials. No host sharing or port grants were copied.'
    end
  end
end
