require_relative 'core'
require 'optparse'

module AgentVM
  class Resources
    def initialize(vm)
      @vm = vm
    end

    def disk_path
      File.join(@vm.tart_directory, 'disk.img')
    end

    def tart_config
      JSON.parse(File.read(File.join(@vm.tart_directory, 'config.json')))
    end

    def snapshot
      actual = tart_config
      disk = File.stat(disk_path)
      memory_path = File.join(@vm.tart_directory, 'state.vzvmsave')
      { 'running'=>@vm.running?, 'suspended'=>@vm.suspended?, 'cpus'=>actual.fetch('cpuCount'),
        'memory_gib'=>actual.fetch('memorySize').fdiv(1024**3),
        'disk_capacity_gb'=>@vm.config.fetch('disk_gb'),
        'disk_format'=>actual.fetch('diskFormat', 'raw'),
        'host_allocated_bytes'=>disk.blocks * 512,
        'saved_memory_bytes'=>File.file?(memory_path) ? File.size(memory_path) : 0 }
    end

    def show(json: false)
      values = snapshot
      return puts(JSON.pretty_generate(values)) if json
      puts "CPU: #{values['cpus']} virtual CPUs"
      puts format('RAM: %g GiB%s', values['memory_gib'], values['running'] ? '' : ' (released while stopped)')
      puts "Disk capacity: #{values['disk_capacity_gb']} GB configured (#{values['disk_format'].upcase})"
      puts format('Host disk allocation: %.2f GB (%.2f GiB)', values['host_allocated_bytes'].fdiv(10**9), values['host_allocated_bytes'].fdiv(1024**3))
      puts format('Saved memory: %.2f GiB (released after successful resume)', values['saved_memory_bytes'].fdiv(1024**3)) if values['saved_memory_bytes'] > 0
      puts 'ASIF reclaims discarded guest blocks automatically. APFS clones and snapshots can retain shared blocks.'
    end

    def image_info
      # Only called under the lifecycle lock with the VM stopped. Even a read
      # through diskutil can interfere with Virtualization.framework startup.
      plist = AgentVM.run('/usr/sbin/diskutil', 'image', 'info', '--plist', disk_path, capture:true, timeout:60)
      JSON.parse(AgentVM.run('/usr/bin/plutil', '-convert', 'json', '-o', '-', '-', input:plist, capture:true))
    end

    def self.partition_size(info, kind)
      parts = info.fetch('Partitions').select { |p| p['content-hint'] == kind }
      raise Error, "Unsupported disk layout: expected one #{kind} partition." unless parts.length == 1
      parts.first.fetch('total-space')
    end

    def self.verify_growth(before, after, requested)
      raise Error, 'Disk growth did not reach the requested capacity.' unless after.fetch('Size Info').fetch('Total Bytes') == requested
      gain = partition_size(after, 'Apple_APFS') - partition_size(before, 'Apple_APFS')
      expected = requested - before.fetch('Size Info').fetch('Total Bytes')
      raise Error, 'The main APFS filesystem did not gain the expected capacity.' if gain < expected - 1024**2
      raise Error, 'Recovery partition changed unexpectedly; inspect the disk before starting.' unless partition_size(before, 'Apple_APFS_Recovery') == partition_size(after, 'Apple_APFS_Recovery')
    end

    def configure(changes)
      @vm.with_lifecycle_lock do
        raise Error, 'Resume and shut down before changing virtual hardware; saved memory requires the same hardware.' if @vm.suspended? || File.file?(@vm.file('suspend.json'))
        job, status = Open3.capture2e('/bin/launchctl', 'print', "#{@vm.domain}/#{@vm.label}")
        if @vm.running? || (status.success? && job.match?(/^\s*state = running$/))
          raise Error, 'Shut down first with vm stop; resource changes do not interrupt a running guest.'
        end
        target = AgentVM.validate(@vm.config.merge(changes))
        actual = tart_config
        cpus = AgentVM.run('/usr/sbin/sysctl', '-n', 'hw.ncpu', capture:true).to_i
        ram = AgentVM.run('/usr/sbin/sysctl', '-n', 'hw.memsize', capture:true).to_i / 1024**3
        raise Error, "This host has #{cpus} CPUs." if target['cpus'] > cpus
        raise Error, 'Reserve at least 4 GiB RAM for the host.' if target['memory_gb'] > ram - 4
        raise Error, 'CPU count is below this macOS image minimum.' if target['cpus'] < actual.fetch('cpuCountMin', 2)
        raise Error, 'RAM is below this macOS image minimum.' if target['memory_gb'] * 1024**3 < actual.fetch('memorySizeMin', 4 * 1024**3)
        if changes.key?('disk_gb')
          raise Error, 'Disk growth is supported for standalone ASIF images.' unless actual['diskFormat'] == 'asif'
          before = image_info
          old_bytes = before.fetch('Size Info').fetch('Total Bytes')
          requested = target['disk_gb'] * 10**9
          raise Error, 'Disk capacity cannot be reduced. Deleting guest files reclaims ASIF storage automatically.' if requested < old_bytes
          if requested > old_bytes
            self.class.partition_size(before, 'Apple_APFS')
            self.class.partition_size(before, 'Apple_APFS_Recovery')
            # Tart uses macOS diskutil image resize, which relocates Recovery
            # and expands the main APFS filesystem on the supported OS.
            AgentVM.run(@vm.tart, 'set', @vm.name, '--disk-size', target['disk_gb'].to_s)
            self.class.verify_growth(before, image_info, requested)
          end
          @vm.config['disk_gb'] = target['disk_gb']
          @vm.save
        end
        AgentVM.run(@vm.tart, 'set', @vm.name, '--cpu', target['cpus'].to_s, '--memory', (target['memory_gb'] * 1024).to_s)
        updated = tart_config
        raise Error, 'Tart did not save the requested CPU/RAM settings.' unless updated['cpuCount'] == target['cpus'] && updated['memorySize'] == target['memory_gb'] * 1024**3
        @vm.config['cpus'], @vm.config['memory_gb'] = target.values_at('cpus', 'memory_gb')
        @vm.save
      end
      show
      puts 'Settings saved. Start with vm start.'
    end

    def command(args)
      changes, json = {}, false
      parser = OptionParser.new do |o|
        o.banner = 'Usage: vm resources [--json | --cpus N --memory GiB --disk GB]'
        o.on('--cpus N', Integer) { |v| changes['cpus'] = v }
        o.on('--memory GiB', Integer) { |v| changes['memory_gb'] = v }
        o.on('--disk GB', Integer) { |v| changes['disk_gb'] = v }
        o.on('--json') { json = true }
        o.on('-h', '--help') { puts o; return }
      end
      parser.parse!(args)
      raise Error, parser.to_s unless args.empty? && !(json && !changes.empty?)
      changes.empty? ? show(json:json) : configure(changes)
    rescue OptionParser::ParseError => e
      raise Error, e.message
    end
  end
end
