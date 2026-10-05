require_relative 'core'
require_relative 'disk-files'
require 'time'

module AgentVM
  # Cold checkpoints include the disk, virtual hardware identity, and SSH keys.
  # They never include, restore, or delete the host's shared project directories.
  class Backups
    FILES = %w[vm/config.json vm/disk.img vm/nvram.bin identity/admin-password identity/id_ed25519 identity/id_ed25519.pub identity/known-hosts].freeze
    def initialize(vm)
      @vm = vm
    end
    def root; @vm.file('snapshots'); end
    def snapshot_path(name)
      raise Error, 'Snapshot names must contain 1-80 letters, digits, underscores or hyphens.' unless name.to_s.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}\z/)
      File.join(root, name)
    end
    def command(args)
      action = args.shift || 'list'
      case action
      when 'list'
        raise Error, 'Usage: vm snapshot list' unless args.empty?
        paths = Dir.glob(File.join(root, '*', 'manifest.json')).sort
        puts 'No snapshots.' if paths.empty?
        paths.each do |path|
          data = JSON.parse(File.read(path))
          puts "#{File.basename(File.dirname(path))}\t#{data['created_at']}"
        end
      when 'create'
        raise Error, 'Usage: vm snapshot create NAME' unless args.length == 1
        stopped { create(snapshot_path(args.first)) }
      when 'restore'
        raise Error, 'Usage: vm snapshot restore NAME' unless args.length == 1
        restore(snapshot_path(args.first))
      when 'verify'
        raise Error, 'Usage: vm snapshot verify NAME' unless args.length == 1
        verify(snapshot_path(args.first))
        puts 'Snapshot checksums verified.'
      when 'delete'
        raise Error, 'Usage: vm snapshot delete NAME' unless args.length == 1
        @vm.with_lifecycle_lock do
          raise Error, 'Finish the interrupted restore before deleting snapshots.' if File.exist?(@vm.file('restore-in-progress.json'))
          path = snapshot_path(args.first)
          # Deleting a named checkpoint must also work when its disk is corrupt;
          # do not read the entire image merely to discard it.
          raise Error, 'Snapshot is missing or is a symlink.' unless File.directory?(path) && !File.symlink?(path) && File.file?(File.join(path, 'manifest.json'))
          FileUtils.remove_entry_secure(path)
          puts 'Snapshot deleted; the current VM is unchanged.'
        end
      else
        raise Error, 'Usage: vm snapshot [list | create NAME | restore NAME | verify NAME | delete NAME]'
      end
    end
    def stopped(allow_missing: false)
      @vm.with_lifecycle_lock do
        raise Error, 'Shut down the VM with vm stop first; backups never interrupt a running session.' if @vm.running?
        raise Error, 'Resolve saved memory and shut down before making a backup.' if @vm.suspended? || File.file?(@vm.file('suspend.json'))
        if File.file?(File.join(@vm.tart_directory, 'config.json'))
          DiskFiles.with_lock(@vm.tart_directory) { yield }
        elsif File.file?(@vm.file('restore-in-progress.json')) || (allow_missing && !File.exist?(File.join(@vm.tart_directory, 'disk.img')))
          yield # A crash can occur between the two directory renames.
        else
          raise Error, 'VM configuration is missing.'
        end
      end
    end
    def copy_file(source, target)
      DiskFiles.copy(source, target)
    end
    def create(destination)
      destination = File.expand_path(destination)
      raise Error, 'Backup destination already exists; choose a new directory.' if File.exist?(destination) || File.symlink?(destination)
      FileUtils.mkdir_p(File.dirname(destination), mode:0700)
      parent = File.realpath(File.dirname(destination))
      destination = File.join(parent, File.basename(destination))
      forbidden_paths = [@vm.tart_directory]
      forbidden_paths.concat(AgentVM.share_entries(@vm.config).map { |entry| entry['host'] })
      forbidden_paths.each do |path|
        forbidden = File.realpath(path)
        raise Error, 'Backups must be outside the shared folder and the live VM directory.' if destination == forbidden || destination.start_with?(forbidden + '/')
      end
      staging = destination + '.partial-' + SecureRandom.hex(6)
      puts 'Copying the stopped VM and computing backup checksums; large disks can take a few minutes.'
      FileUtils.mkdir_p(staging, mode:0700)
      manifest = {'format'=>1, 'created_at'=>Time.now.utc.iso8601, 'name'=>@vm.name,
                  'guest'=>AgentVM.guest_config(@vm.config), 'files'=>{}}
      FILES.each do |relative|
        source = relative.start_with?('vm/') ? File.join(@vm.tart_directory, relative.delete_prefix('vm/')) : @vm.file(relative.delete_prefix('identity/'))
        raise Error, "Required backup file is missing or is a symlink: #{relative}" unless File.file?(source) && !File.symlink?(source)
        target = File.join(staging, relative)
        copy_file(source, target)
        manifest['files'][relative] = {'size'=>File.size(target), 'sha256'=>Digest::SHA256.file(target).hexdigest}
      end
      AgentVM.json_write(File.join(staging, 'manifest.json'), manifest)
      AgentVM.run('/bin/sync', capture:true)
      File.rename(staging, destination)
      @vm.exclude_backup(File.join(destination, 'vm/disk.img'))
      puts "Saved: #{destination}"
      puts 'Includes guest data and private credentials. Shared host files are outside this backup.'
      destination
    ensure
      FileUtils.remove_entry_secure(staging) if staging && File.directory?(staging)
    end
    def verify(path)
      path = File.expand_path(path)
      raise Error, 'Backup directory is missing or is a symlink.' unless File.directory?(path) && !File.symlink?(path)
      %w[vm identity].each do |sub|
        dir = File.join(path, sub)
        raise Error, 'Unsafe backup directory.' unless File.directory?(dir) && !File.symlink?(dir)
      end
      manifest = File.join(path, 'manifest.json')
      raise Error, 'Backup manifest is missing or is a symlink.' unless File.file?(manifest) && !File.symlink?(manifest)
      data = JSON.parse(File.read(manifest))
      raise Error, 'Unrecognized backup format or file list.' unless data.is_a?(Hash) && data['format'] == 1 && data['files'].is_a?(Hash) && data['files'].keys.sort == FILES.sort && data['guest'].is_a?(Hash)
      AgentVM.validate(@vm.config.merge(data['guest']))
      FILES.each do |relative|
        file = File.join(path, relative)
        expected = data['files'].fetch(relative)
        raise Error, "Backup file is missing or unsafe: #{relative}" unless File.file?(file) && !File.symlink?(file)
        raise Error, "Backup checksum mismatch: #{relative}" unless expected.is_a?(Hash) && File.size(file) == expected['size'] && Digest::SHA256.file(file).hexdigest == expected['sha256']
      end
      raise Error, 'Backup guest account differs from this VM.' unless data.fetch('guest').fetch('user') == @vm.config['user']
      data
    rescue JSON::ParserError, KeyError, Errno::ENOENT => error
      raise Error, "Invalid or incomplete backup: #{error.message}"
    end
    def restore(path)
      raise Error, 'Backup directory is missing or is a symlink.' unless File.directory?(path) && !File.symlink?(path)
      path = File.realpath(path)
      raise Error, 'Restore source must be outside the live VM directory.' if path.start_with?(File.expand_path(@vm.tart_directory) + '/')
      stopped(allow_missing:true) do
        raise Error, 'An earlier restore was interrupted; run vm restore --recover.' if File.exist?(@vm.file('restore-in-progress.json'))
        data = verify(path)
        if File.exist?(File.join(@vm.tart_directory, 'disk.img'))
          before_name = 'before-restore-' + Time.now.utc.strftime('%Y%m%dT%H%M%S') + '-' + SecureRandom.hex(3)
          before = create(snapshot_path(before_name))
        end
        AgentVM.json_write(@vm.file('restore-in-progress.json'), {'before'=>before_name, 'source'=>path})
        begin
          replace(path, data)
        rescue StandardError
          if before
            replace(before, verify(before))
            File.unlink(@vm.file('restore-in-progress.json'))
          end
          raise
        end
        File.unlink(@vm.file('restore-in-progress.json'))
        puts before ? "Restored. Previous VM preserved as snapshot #{before_name}." : 'Missing VM disk restored from backup.'
        puts 'Current host sharing and port grants are retained. Run vm apply to refresh guest configuration, then vm ssh.'
      end
    end
    def recover
      stopped do
        path = @vm.file('restore-in-progress.json')
        raise Error, 'No interrupted restore to recover.' unless File.file?(path)
        journal = JSON.parse(File.read(path))
        source = journal['before'] ? snapshot_path(journal['before']) : journal.fetch('source')
        replace(source, verify(source))
        File.unlink(path)
        puts 'Recovered the VM from the saved restore checkpoint.'
      end
    end
    def replace(path, data)
      # Stage beside the Tart storage root, so the final rename stays atomic.
      temporary = File.join(File.dirname(File.dirname(@vm.tart_directory)), '.agent-vm-restore-' + SecureRandom.hex(8))
      old = temporary + '-previous'
      FileUtils.mkdir_p(temporary, mode:0700)
      %w[config.json disk.img nvram.bin].each { |file| copy_file(File.join(path, 'vm', file), File.join(temporary, file)) }
      DiskFiles.with_lock(temporary) do
        File.rename(@vm.tart_directory, old) if File.directory?(@vm.tart_directory)
        File.rename(temporary, @vm.tart_directory)
        FILES.grep(/^identity\//).each do |relative|
          file = relative.delete_prefix('identity/')
          content = File.binread(File.join(path, relative))
          content = @vm.name + ' ' + content.split[1, 2].join(' ') + "\n" if file == 'known-hosts'
          AgentVM.write(@vm.file(file), content)
        end
        %w[cpus memory_gb disk_gb profiles agents python].each { |key| @vm.config[key] = data['guest'][key] if data['guest'].key?(key) }
        @vm.config['credential_relay_cleanup'] = true
        @vm.save
        @vm.render_host
        @vm.exclude_backup
        AgentVM.run('/bin/sync', capture:true)
      end
    ensure
      FileUtils.remove_entry_secure(temporary) if temporary && File.directory?(temporary)
      # The complete pre-restore snapshot remains even if interruption occurs.
      FileUtils.remove_entry_secure(old) if old && File.directory?(old)
    end
  end
end
