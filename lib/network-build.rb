require_relative 'core'
require 'tmpdir'

module AgentVM
  class NetworkBuild
    LIBRARY = 'github.com/containers/gvisor-tap-vsock'.freeze
    GO = '/opt/homebrew/bin/go'.freeze
    def initialize(vm); @vm = vm; end
    def root; File.join(AgentVM.state_root, 'network-builds'); end
    def sources; Dir.glob(File.join(__dir__, 'network', '*.go')).sort; end
    def digest
      @digest ||= source_digest
    end
    def source_digest
      Digest::SHA256.hexdigest(([__FILE__] + sources).map { |file| Digest::SHA256.file(file).hexdigest }.join)
    end
    def validate_version(version)
      raise Error, 'Invalid VPN networking library version.' unless version.is_a?(String) && version.match?(/\Av\d+\.\d+\.\d+(?:[-.][A-Za-z0-9]+)*\z/)
      version
    end
    def directory(version)
      File.join(root, Digest::SHA256.hexdigest(digest + validate_version(version))[0,24])
    end
    def receipt(directory)
      manifest = JSON.parse(File.read(File.join(directory, 'manifest.json')))
      binary = File.join(directory, 'bin/softnet')
      return unless File.executable?(binary) && !File.symlink?(binary)
      return unless Digest::SHA256.file(binary).hexdigest == manifest['binary_sha256']
      manifest
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end
    def legacy_version
      # An existing running/stopped VM can keep its recorded dependency when
      # migrating from the old source-only cache. Fresh installs resolve latest.
      state = JSON.parse(File.read(@vm.file('network-state.json')))
      binary = File.expand_path(state.fetch('binary'))
      return unless binary.start_with?(root + '/') && binary.end_with?('/bin/softnet')
      manifest = receipt(File.dirname(File.dirname(binary)))
      validate_version(manifest['network_library']) if manifest
    rescue Errno::ENOENT, JSON::ParserError, KeyError, Error
      nil
    end
    def current_version
      version = @vm.config['network_library_version'] || legacy_version
      validate_version(version) if version
    end
    def used?; !!current_version || @vm.config['network_mode'] == 'vpn'; end
    def command
      ['/usr/bin/env', 'GOWORK=off', 'GOTELEMETRY=off', "GOMODCACHE=#{root}/modules", "GOCACHE=#{root}/cache", GO]
    end
    def prepare_go
      AgentVM.run('/opt/homebrew/bin/brew', 'install', 'go') unless File.executable?(GO)
      FileUtils.mkdir_p(root, mode:0700)
      @vm.exclude_backup(root)
    end
    def latest_version(prepare: true)
      prepare_go if prepare
      Dir.mktmpdir('network-version-') do |temporary|
        data = AgentVM.run(*command, '-C', temporary, 'list', '-m', '-json', LIBRARY + '@latest', capture:true, timeout:120)
        validate_version(JSON.parse(data).fetch('Version'))
      end
    end
    def ready?(version)
      manifest = receipt(directory(version))
      manifest && manifest['source_digest'] == digest && manifest['network_library'] == version
    end
    def install(version = current_version || latest_version, persist: true)
      destination = directory(version)
      binary = File.join(destination, 'bin/softnet')
      unless ready?(version)
        FileUtils.mkdir_p(destination, mode:0700)
        File.open(File.join(destination, 'build.lock'), File::RDWR|File::CREAT, 0600) do |lock|
          raise Error, 'VPN networking is already being built; retry when it finishes.' unless lock.flock(File::LOCK_EX|File::LOCK_NB)
          compile(version, destination) unless ready?(version)
        end
      end
      # Never select an incomplete build or replace a running helper. Retained
      # copies keep their own version and immutable executable in this cache.
      if @vm.config['network_library_version'] != version
        @vm.config['network_library_version'] = version
        @vm.save if persist
      end
      binary
    end
    def compile(version, destination)
      prepare_go
      source = File.join(destination, 'source')
      FileUtils.mkdir_p(source, mode:0700)
      FileUtils.cp(sources, source)
      puts "Building VPN-compatible networking (#{version}); completed builds are reused."
      args = command + ['-C', source]
      AgentVM.run(*args, 'mod', 'init', 'second-mac-network', capture:true) unless File.file?(File.join(source, 'go.mod'))
      AgentVM.run(*args, 'get', LIBRARY + '@' + version, timeout:600)
      AgentVM.run(*args, 'mod', 'tidy', timeout:600)
      AgentVM.run(*args, 'test', './...', timeout:600)
      dependency = JSON.parse(AgentVM.run(*args, 'list', '-m', '-json', LIBRARY, capture:true))
      raise Error, 'VPN dependency resolution changed; the existing helper was retained.' unless dependency['Version'] == version
      binary = File.join(destination, 'bin/softnet')
      FileUtils.mkdir_p(File.dirname(binary), mode:0700)
      expected_digest = digest
      AgentVM.run(*args, 'build', '-trimpath', '-ldflags=-s -w', '-o', binary + '.new', '.', timeout:600)
      AgentVM.run('/usr/bin/codesign', '--force', '--sign', '-', binary + '.new', capture:true)
      AgentVM.run('/usr/bin/codesign', '--verify', '--strict', binary + '.new', capture:true)
      raise Error, 'Network sources changed during compilation; retry the update.' unless expected_digest == source_digest
      File.rename(binary + '.new', binary)
      AgentVM.json_write(File.join(destination, 'manifest.json'), {'source_digest'=>digest,
        'binary_sha256'=>Digest::SHA256.file(binary).hexdigest, 'network_library'=>version})
    end
    def update
      return unless used?
      version = latest_version
      # The combined updater saves all selected host dependencies together,
      # after the optional Tart build succeeds. Do not publish them early.
      install(version, persist:false)
      puts "VPN networking library: #{version}. Existing connections retain their running helper until a network switch or VM start."
    end
    def check
      return unless used?
      # A check must not install a compiler on a machine that does not have it.
      latest = File.executable?(GO) ? latest_version(prepare:false) : 'checked during vm update (Go is not installed)'
      puts "VPN networking library: installed #{current_version || 'not built'}; latest #{latest}"
    end
  end
end
