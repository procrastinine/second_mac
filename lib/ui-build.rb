require_relative 'core'
require 'tmpdir'

module AgentVM
  # An optional local build of the installed upstream Tart release, adding a
  # private display endpoint and independent audio directions.
  class UIBuild
    def initialize(vm); @vm = vm; end
    def digest
      @digest ||= source_digest
    end
    def source_digest
      files = [__FILE__] + %w[display tart-patches third-party].flat_map { |part| Dir.glob(File.join(__dir__, part, '**', '*')) }.select { |p| File.file?(p) }.sort
      Digest::SHA256.hexdigest(files.map { |p| Digest::SHA256.file(p).hexdigest }.join)
    end
    def release_tag
      value = @vm.config.fetch('tart_version')
      raise Error, 'Unrecognized Tart release version.' unless value.match?(/\Av?\d+\.\d+\.\d+(?:[-.][A-Za-z0-9]+)*\z/)
      value
    end
    def version; release_tag.sub(/\Av/, ''); end
    def directory
      File.join(AgentVM.state_root, 'ui-builds', version + '-' + digest[0,16])
    end
    def binary; File.join(directory, 'tart'); end
    def source_directory
      # Share compiler/dependency caches across patch changes to this release.
      # Finished executables stay immutable so old copies keep their build.
      File.join(AgentVM.state_root, 'ui-builds', 'source-' + version)
    end
    def ready?
      return false unless File.executable?(binary) && File.file?(File.join(directory, 'manifest.json'))
      manifest = JSON.parse(File.read(File.join(directory, 'manifest.json')))
      manifest['source_digest'] == digest && manifest['binary_sha256'] == Digest::SHA256.file(binary).hexdigest
    rescue JSON::ParserError, Errno::ENOENT
      false
    end
    def self.replace_once(text, before, after)
      raise Error, 'The current Tart source changed; update Second Mac before building its UI extension, or select regular Tart with --runtime standard.' unless text.scan(before).length == 1
      text.sub(before, after)
    end
    def checkout
      source = source_directory
      raise Error, 'Unsafe UI source cache.' if File.symlink?(source) || (File.exist?(source) && !File.directory?(source))
      complete = if File.directory?(File.join(source, '.git'))
        begin
          AgentVM.run('/usr/bin/git', '-C', source, 'rev-parse', '--verify', 'HEAD', capture:true).strip.match?(/\A[0-9a-f]{40}\z/)
        rescue Error
          false
        end
      end
      unless complete
        # This is a generated cache, never the Second Mac checkout. Older
        # interrupted clones can leave an empty directory; retries repair it.
        FileUtils.remove_entry_secure(source) if File.directory?(source)
        incoming = Dir.mktmpdir('.source-' + version + '-', File.dirname(source))
        puts "Building guest-only UI support for Tart #{version}; first build downloads upstream build dependencies."
        AgentVM.run('/usr/bin/git', 'clone', '--depth', '1', '--branch', release_tag, 'https://github.com/openai/tart.git', incoming, timeout:600)
        commit = AgentVM.run('/usr/bin/git', '-C', incoming, 'rev-parse', 'HEAD', capture:true).strip
        tag = AgentVM.run('/usr/bin/git', '-C', incoming, 'rev-parse', "refs/tags/#{release_tag}^{commit}", capture:true).strip
        raise Error, 'Incomplete upstream release checkout.' unless commit.match?(/\A[0-9a-f]{40}\z/) && commit == tag
        File.rename(incoming, source)
      end
      source
    ensure
      FileUtils.remove_entry_secure(incoming) if incoming && File.directory?(incoming)
    end
    def patch(source)
      target = File.join(source, 'Sources', 'SecondMacDisplay')
      raise Error, 'Unsafe generated display source directory.' if File.symlink?(target)
      FileUtils.remove_entry_secure(target) if File.directory?(target)
      FileUtils.mkdir_p(target)
      FileUtils.cp_r(Dir.glob(File.join(__dir__, 'display', '*')), target)
      # The guest agent discovers Tart through its virtual console version.
      # Unexpanded upstream source advertises SNAPSHOT and breaks that transport.
      path = File.join(source, 'Sources/tart/CI/CI.swift')
      File.write(path, self.class.replace_once(File.read(path), '${VERSION}', version))
      path = File.join(source, 'Package.swift')
      text = File.read(path)
      # String form works with Swift PackageDescription 5.10 as well as 6.x.
      text = text.sub('.macOS(.v13)', '.macOS("14.4")')
      text = self.class.replace_once(text, '  targets: [', "  targets: [\n    .target(name: \"SecondMacDisplay\", path: \"Sources/SecondMacDisplay\", publicHeadersPath: \"include\", cSettings: [.unsafeFlags([\"-fobjc-arc\"])]),")
      text = self.class.replace_once(text, '.executableTarget(name: "tart", dependencies: [', ".executableTarget(name: \"tart\", dependencies: [\n      \"SecondMacDisplay\",")
      # Keep the small no-op tracing API for upstream call-site compatibility;
      # omit all exporters, resource collection and the unused formatter tool.
      %w[https://github.com/nicklockwood/SwiftFormat https://github.com/open-telemetry/opentelemetry-swift].each do |url|
        # Match the dependency identity, not an unrelated formatter version or
        # telemetry branch. Changed/ambiguous source structure still fails closed.
        dependency = /^[ \t]*\.package\(\s*url:\s*"#{Regexp.escape(url)}"\s*,\s*(?:from|exact|branch|revision):\s*"[^"]+"\s*\),[ \t]*\n/
        text = self.class.replace_once(text, dependency, '')
      end
      [
        '      .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),',
        '      .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),',
        '      .product(name: "ResourceExtension", package: "opentelemetry-swift"),'
      ].each { |line| text = self.class.replace_once(text, line + "\n", '') }
      File.write(path, text)
      FileUtils.cp(File.join(__dir__, 'tart-patches', 'OTel.swift'), File.join(source, 'Sources/tart/OTel.swift'))
      path = File.join(source, 'Sources/tart/Root.swift')
      text = File.read(path)
      %w[OpenTelemetrySdk OpenTelemetryProtocolExporterHttp].each do |name|
        text = self.class.replace_once(text, "import #{name}\n", '')
      end
      text = self.class.replace_once(text, /^  private static func startCommandSpan\(for command: ParsableCommand\) -> Span \{\n.*?^  \}/m, <<~'SWIFT'.lines.map { |line| '  ' + line }.join.rstrip)
        private static func startCommandSpan(for command: ParsableCommand) -> Span {
          return OTel.shared.tracer.spanBuilder(spanName: "tart").startSpan()
        }
      SWIFT
      File.write(path, text)
      path = File.join(source, 'Sources/tart/VM.swift')
      FileUtils.cp(File.join(__dir__, 'tart-patches', 'SecondMacAudio.swift'), File.join(source, 'Sources/tart/SecondMacAudio.swift'))
      text = self.class.replace_once(File.read(path), /    let soundDeviceConfiguration = VZVirtioSoundDeviceConfiguration\(\)\n.*?    configuration.audioDevices = \[soundDeviceConfiguration\]/m,
        '    configuration.audioDevices = [SecondMacAudio.device(audio: audio, suspendable: suspendable)]')
      text = self.class.replace_once(text, '    // Networking', <<~'SWIFT'.lines.map { |line| '    ' + line }.join.rstrip)
        // Reserve empty devices so a host-only controller can add or replace
        // managed shares without changing this VM's hardware. Empty means no
        // host resources; throwaways still start with no shares attached.
        if ProcessInfo.processInfo.environment["SECOND_MAC_MANAGED"] == "1" {
          var devices = directorySharingDevices
          for tag in ["agent-files", "agent-readonly", "agent-linked"] {
            if !devices.contains(where: { ($0 as? VZVirtioFileSystemDeviceConfiguration)?.tag == tag }) {
              devices.append(VZVirtioFileSystemDeviceConfiguration(tag: tag))
            }
          }
          // Device order is part of save/restore compatibility. Upstream's
          // Dictionary(grouping:).map order changes between processes.
          configuration.directorySharingDevices = devices.sorted {
            (($0 as? VZVirtioFileSystemDeviceConfiguration)?.tag ?? "") <
            (($1 as? VZVirtioFileSystemDeviceConfiguration)?.tag ?? "")
          }
        }

        // Fixed virtual pointing device for Second Mac's guest-only controller.
        // Physical USB passthrough remains disabled by --no-usb-accessories.
        if ProcessInfo.processInfo.environment["SECOND_MAC_MANAGED"] == "1" || ProcessInfo.processInfo.environment["SECOND_MAC_UI"] == "1" {
          configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }

        // Networking
      SWIFT
      text = self.class.replace_once(text, '    configuration.directorySharingDevices = directorySharingDevices',
        '    if ProcessInfo.processInfo.environment["SECOND_MAC_MANAGED"] != "1" { configuration.directorySharingDevices = directorySharingDevices }')
      File.write(path, text)
      candidates = %w[Sources/tart/Commands/Run.swift Sources/tart/Run.swift].map { |p| File.join(source,p) }.select { |p| File.file?(p) }
      raise Error, 'Cannot locate the upstream Tart runner.' unless candidates.length == 1
      path = candidates.first
      text = self.class.replace_once(File.read(path), 'import Virtualization', "import Virtualization\nimport SecondMacDisplay")
      text = self.class.replace_once(text, '        var resume = false', <<~'SWIFT'.lines.map { |line| '        ' + line }.join.rstrip)
        if ProcessInfo.processInfo.environment["SECOND_MAC_RESUME"] == "1" && !FileManager.default.fileExists(atPath: vmDir.stateURL.path) {
          throw ValidationError("Requested memory resume has no saved state; refusing a cold boot")
        }
        var resume = false
      SWIFT
      # Managed resumes use the exact saved hardware, rather than upstream's
      # legacy --suspendable profile (which disables audio and entropy).
      text = self.class.replace_once(text, '    if try vmDir.state() == .Suspended {',
        '    if try vmDir.state() == .Suspended && ProcessInfo.processInfo.environment["SECOND_MAC_MANAGED"] != "1" {')
      text = self.class.replace_once(text, '              try FileManager.default.removeItem(at: vmDir.stateURL)',
        '              // Keep the state until resume succeeds; a failed restore remains retryable.')
      text = self.class.replace_once(text, '        } catch let error as VZError {', <<~'SWIFT'.lines.map { |line| '        ' + line }.join.rstrip)
          if resume {
            try FileManager.default.removeItem(at: vmDir.stateURL)
          }
        } catch let error as VZError {
      SWIFT
      text = self.class.replace_once(text, '        try await vm!.run()', <<~'SWIFT'.lines.map { |line| '        ' + line }.join.rstrip)
        if ProcessInfo.processInfo.environment["SECOND_MAC_UI"] == "1" {
          let result = await MainActor.run { SMStartControl(vm!.virtualMachine, vmDir.baseURL.path) }
          guard result == 0 else { throw ValidationError("Could not create private Second Mac UI socket") }
        }
        if ProcessInfo.processInfo.environment["SECOND_MAC_MANAGED"] == "1" {
          let result = await MainActor.run { SMStartRuntimeControl(vm!.virtualMachine, vm!.configuration, vmDir.baseURL.path) }
          guard result == 0 else { throw ValidationError("Could not create private Second Mac runtime socket") }
        }
        try await vm!.run()
      SWIFT
      File.write(path, text)
    end
    def install
      return binary if ready?
      FileUtils.mkdir_p(directory, mode:0700)
      File.open(source_directory + '.lock', File::RDWR|File::CREAT, 0600) do |lock|
        raise Error, 'Another VM UI build is in progress.' unless lock.flock(File::LOCK_EX|File::LOCK_NB)
        return binary if ready?
        source = checkout
        # A failed build is resumable. Reset only this tool-owned upstream
        # checkout, never the user's Second Mac repository or VM files.
        commit = AgentVM.run('/usr/bin/git', '-C', source, 'rev-parse', 'HEAD', capture:true).strip
        raise Error, 'Invalid upstream revision.' unless commit.match?(/\A[0-9a-f]{40}\z/)
        release_commit = AgentVM.run('/usr/bin/git', '-C', source, 'rev-parse', "refs/tags/#{release_tag}^{commit}", capture:true).strip
        raise Error, 'UI checkout is not the installed Tart release tag.' unless release_commit == commit
        # Restore missing tracked files as well as modified ones. A checkout
        # interrupted after HEAD was saved must also recover on its next run.
        AgentVM.run('/usr/bin/git', '-C', source, 'restore', '--source=HEAD', '--worktree', '--', '.', capture:true)
        patch(source)
        AgentVM.run('/usr/bin/xcrun', 'swift', 'build', '--package-path', source, '-c', 'release', '--product', 'tart', timeout:3600)
        incoming = binary + '.new'
        FileUtils.cp(File.join(source, '.build/release/tart'), incoming)
        File.chmod(0755, incoming)
        entitlement = File.join(directory, 'entitlements.plist')
        AgentVM.write(entitlement, AgentVM.plist('com.apple.security.virtualization'=>true))
        AgentVM.run('/usr/bin/codesign', '--force', '--sign', '-', '--entitlements', entitlement, incoming, capture:true)
        AgentVM.run('/usr/bin/codesign', '--verify', '--strict', incoming, capture:true)
        raise Error, 'UI patch sources changed during compilation; rerun the update to build the current sources.' unless source_digest == digest
        File.rename(incoming, binary)
        %w[LICENSE NOTICE].each do |name|
          FileUtils.cp(File.join(source, name), File.join(directory, name)) if File.file?(File.join(source, name))
        end
        FileUtils.cp(File.join(__dir__, 'third-party/CUA-LICENSE.txt'), File.join(directory, 'CUA-LICENSE.txt'))
        AgentVM.json_write(File.join(directory, 'manifest.json'), {'tart_version'=>version, 'upstream_commit'=>commit,
          'source_digest'=>digest, 'binary_sha256'=>Digest::SHA256.file(binary).hexdigest})
        @vm.exclude_backup(directory, source)
      end
      binary
    end
  end
end
