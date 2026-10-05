require_relative 'core'
require_relative 'install'

module AgentVM
  module SwiftBar
    # Earlier builds have disabled submenu actions and macOS 27 menu bugs.
    # This is a compatibility floor, not the version selected for installation.
    MIN_BUILD = 623
    TEAM = 'X93LWC49WV'

    def self.release_asset(releases)
      candidates = releases.reject { |r| r['draft'] }.map do |release|
        asset = release.fetch('assets').find do |a|
          build = a.fetch('name').match(/\ASwiftBar\..*\.b(\d+)\.zip\z/)
          build && build[1].to_i >= MIN_BUILD
        end
        [release, asset] if asset
      end
      candidates.compact!
      candidates.select { |r, _| !r['prerelease'] }.max_by { |r, _| r['published_at'] } ||
        candidates.max_by { |r, _| r['published_at'] }
    end

    def self.application
      ['/Applications/SwiftBar.app', File.join(Dir.home, 'Applications/SwiftBar.app')].find { |path| File.directory?(path) }
    end

    def self.install(vm)
      installer = Installer.new(vm.config)
      metadata = vm.file('swiftbar-releases.json')
      installer.download('https://api.github.com/repos/swiftbar/SwiftBar/releases?per_page=30', metadata)
      selected = release_asset(JSON.parse(File.read(metadata)))
      raise Error, 'No compatible official SwiftBar release found.' unless selected
      release, asset = selected
      wanted_build = asset.fetch('name').match(/\.b(\d+)\.zip\z/)[1].to_i
      application = self.application
      if application
        current = AgentVM.run('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleVersion', File.join(application,'Contents/Info.plist'), capture:true).to_i
      end
      if !application || current < wanted_build
        puts "Installing official SwiftBar #{release.fetch('tag_name')}#{release['prerelease'] ? ' (beta required for current menu fixes)' : ''}."
        digest = asset['digest'].to_s
        raise Error, 'SwiftBar release is missing its SHA-256 digest.' unless digest.match?(/\Asha256:[0-9a-f]{64}\z/)
        archive = vm.file('swiftbar.zip')
        installer.download(asset.fetch('browser_download_url'), archive)
        raise Error, 'SwiftBar checksum mismatch.' unless 'sha256:' + Digest::SHA256.file(archive).hexdigest == digest
        extracted = vm.file('swiftbar-unpack')
        FileUtils.rm_rf(extracted)
        AgentVM.run('/usr/bin/ditto', '-xk', archive, extracted)
        incoming = File.join(extracted, 'SwiftBar.app')
        AgentVM.run('/usr/bin/codesign', '--verify', '--deep', '--strict', '-R', "anchor apple generic and certificate leaf[subject.OU] = \"#{TEAM}\"", incoming)
        installed_build = AgentVM.run('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleVersion', File.join(incoming,'Contents/Info.plist'), capture:true).to_i
        raise Error, 'SwiftBar release build differs from its metadata.' unless installed_build == wanted_build
        application ||= File.join(Dir.home, 'Applications/SwiftBar.app')
        FileUtils.mkdir_p(File.dirname(application))
        raise Error, "SwiftBar app folder is not writable: #{File.dirname(application)}" unless File.writable?(File.dirname(application))
        if File.directory?(application)
          system('/usr/bin/killall', '-TERM', 'SwiftBar', out:File::NULL, err:File::NULL)
          backup = vm.file('backups/SwiftBar-' + Time.now.utc.strftime('%Y%m%d%H%M%S') + '.app')
          FileUtils.mkdir_p(File.dirname(backup))
          FileUtils.mv(application, backup)
        end
        begin
          AgentVM.run('/usr/bin/ditto', incoming, application)
        rescue StandardError
          FileUtils.rm_rf(application)
          FileUtils.mv(backup, application) if backup && File.directory?(backup)
          raise
        end
        FileUtils.rm_rf(extracted)
        File.unlink(archive)
      end
      AgentVM.run('/usr/bin/defaults', 'write', 'com.ameba.SwiftBar', 'CollectCrashReports', '-bool', 'false')
      # Manual vm update/menubar install resolves the official release.
      AgentVM.run('/usr/bin/defaults', 'write', 'com.ameba.SwiftBar', 'SUEnableAutomaticChecks', '-bool', 'false')
      AgentVM.write(File.join(Dir.home, 'Library/LaunchAgents/local.agent-vm.swiftbar.plist'), AgentVM.plist({
        'Label'=>'local.agent-vm.swiftbar', 'ProgramArguments'=>['/usr/bin/open','-g','-a',application],
        'RunAtLoad'=>true, 'KeepAlive'=>false,
      }))
      application
    end
  end
end
