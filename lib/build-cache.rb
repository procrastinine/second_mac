require_relative 'core'

module AgentVM
  # Only compiler intermediates are disposable here. Finished runtimes can be
  # pinned by saved memory or retained copies; never prune those automatically.
  class BuildCache
    def root; File.join(AgentVM.state_root, 'ui-builds'); end
    def records
      paths = Dir.glob(File.join(AgentVM.state_root, '*', '{config,suspend,access-launch}.json'))
      paths.map { |path| JSON.parse(File.read(path)) }
    rescue JSON::ParserError, SystemCallError
      raise Error, 'Cannot inspect all runtime references; compiler caches were kept.'
    end
    def references(value)
      case value
      when Hash
        value.flat_map do |key, child|
          if %w[tart ui_tart binary].include?(key) && child.is_a?(String) && child.start_with?(root + '/')
            [File.exist?(child) ? File.realpath(child) : child]
          else
            references(child)
          end
        end
      when Array then value.flat_map { |child| references(child) }
      else []
      end
    end
    def entries
      data = records
      versions = data.map { |record| record['tart_version'].to_s.sub(/\Av/, '') }.reject(&:empty?).uniq
      paths = references(data)
      candidates = Dir.glob(File.join(root, '*', '.build')) + Dir.glob(File.join(root, '*', 'source', '.build'))
      candidates.sort.map do |path|
        parent = File.dirname(path)
        directory = File.basename(parent) == 'source' ? File.dirname(parent) : parent
        name = File.basename(directory)
        version = name[/\A(?:source-)?(\d+\.\d+\.\d+)(?:-[0-9a-f]{16})?\z/, 1]
        next unless version && File.directory?(path) && !File.symlink?(path) && !File.symlink?(parent) && !File.symlink?(directory)
        real = File.realpath(path)
        pinned = paths.any? { |reference| reference == real || reference.start_with?(real + '/') }
        keep = pinned ? 'referenced runtime' : (versions.include?(version) ? 'current release; keeps rebuilds fast' : nil)
        bytes = AgentVM.run('/usr/bin/du', '-sk', path, capture:true, timeout:30).split.first.to_i * 1024
        {'path'=>path, 'version'=>version, 'bytes'=>bytes, 'keep'=>keep}
      end.compact
    end
    def clean
      entries.each do |entry|
        next if entry['keep']
        File.open(File.join(root, 'source-' + entry['version'] + '.lock'), File::RDWR | File::CREAT, 0600) do |lock|
          raise Error, 'A compiler is using this release; retry cache cleanup after it finishes.' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          # Recheck after acquiring the build lock, since another installation
          # may have selected this release while storage was being inspected.
          current = entries.find { |item| item['path'] == entry['path'] }
          next unless current && !current['keep']
          FileUtils.remove_entry_secure(entry['path'])
          puts format('Removed %.2f GiB of obsolete compiler intermediates for Tart %s.', entry['bytes'].fdiv(1024**3), entry['version'])
        end
      end
      puts 'Current compiler cache, finished executables, restore images, VM disks and saved memory were kept.'
    end
    def command(args)
      case args
      when [], ['list']
        rows = entries
        puts 'No Tart compiler caches.' if rows.empty?
        rows.each do |entry|
          puts format('Tart %s: %.2f GiB — %s', entry['version'], entry['bytes'].fdiv(1024**3), entry['keep'] || 'obsolete; vm cache clean can remove it')
        end
      when ['clean'] then clean
      else raise Error, 'Usage: vm cache [list | clean] (obsolete compiler intermediates only)'
      end
    end
  end
end
