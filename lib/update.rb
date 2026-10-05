require_relative 'core'
require_relative 'install'
require_relative 'guest-update'
require_relative 'build-cache'
require_relative 'network-build'
require 'optparse'

module AgentVM
  # Updating the checkout and updating installed VM software are separate steps:
  # execute the newly fetched implementation, never an old in-memory installer.
  class RepositoryUpdate
    def initialize(source)
      @source = source
    end

    def git(*args)
      AgentVM.run('/usr/bin/git', '-C', @source, *args, capture:true, timeout:120)
    end

    def refresh(check: false)
      unless @source && File.directory?(@source)
        puts 'Source checkout unavailable; using the installed VM configuration.'
        return
      end
      begin
        root = git('rev-parse', '--show-toplevel').strip
        upstream = git('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}').strip
      rescue Error
        puts 'No Git upstream configured; using the local VM configuration.'
        return
      end
      raise Error, 'Source directory is not the repository root.' unless File.realpath(root) == File.realpath(@source)
      dirty = !git('status', '--porcelain', '--untracked-files=all').empty?
      if dirty && !check
        raise Error, 'Source checkout has local changes. Commit/stash them, or use vm update --no-pull to use them as-is.'
      end
      git('fetch', '--no-tags', '--prune')
      ahead, behind = git('rev-list', '--left-right', '--count', 'HEAD...@{upstream}').split.map(&:to_i)
      puts "VM repository: #{ahead} commits ahead, #{behind} behind #{upstream}#{dirty ? ' (local edits retained)' : ''}."
      return if check
      raise Error, 'Source checkout diverged from its upstream; resolve it before updating.' if ahead > 0 && behind > 0
      git('merge', '--ff-only', '@{upstream}') if behind > 0
    end
  end

  class MacOSUpdate
    def initialize(vm)
      @vm = vm
    end

    def check
      # Apple writes "No new software available." to stderr even on success.
      # Preserve both streams so an up-to-date guest is not a parse failure.
      @vm.ssh('/bin/sh', '-c', 'exec /usr/sbin/softwareupdate --list --product-types macOS 2>&1', timeout:600, capture:true)
    end

    def install
      catalog = check
      puts catalog
      return false if catalog.include?('No new software available.')
      # Do not infer "up to date" from an unrecognized or failed scan.
      raise Error, 'Cannot interpret the macOS update catalog; inspect vm update --macos --check.' unless catalog.include?('* Label:')
      return false unless catalog.include?('Recommended: YES')
      before = @vm.ssh('/usr/bin/sw_vers', '-buildVersion', capture:true).strip
      needs_restart = catalog.include?('Action: restart') || catalog.include?('Action: shut down')
      disconnected = false
      begin
        # sudo consumes the first password line in VM#root; softwareupdate
        # consumes the second. No secret is put in argv, logs, or the share.
        @vm.root('/usr/sbin/softwareupdate', '--install', '--recommended', '--os-only',
                 '--restart', '--agree-to-license', '--user', @vm.config.fetch('user'),
                 '--stdinpass', input:@vm.password + "\n", timeout:10_800)
      rescue Error => e
        # An SSH disconnect is expected on reboot, but is not proof of success.
        raise unless e.message.start_with?('ssh failed (255):')
        disconnected = true
      end
      if needs_restart || disconnected
        @vm.wait_for(1800, 'Waiting for updated macOS to boot') do
          @vm.launch unless @vm.running?
          after = @vm.ssh('/usr/bin/sw_vers', '-buildVersion', capture:true, timeout:15).strip
          !after.empty? && after != before
        end
        @vm.start # Restore explicit forwards and sharing after reboot/shutdown.
      end
      puts @vm.ssh('/usr/bin/sw_vers', capture:true)
      true
    rescue Error => e
      raise Error, "macOS update was not verified: #{e.message}\nKeep the VM running while Apple completes installation; use vm update --macos --check to inspect it."
    end
  end

  class Update
    def initialize(vm)
      @vm = vm
    end

    def command(argv)
      options = {check:false, plan:false, pull:@vm.config.fetch('source_mode', 'git') == 'git', second_mac_only:false, macos_only:false, configuration:false}
      parser = OptionParser.new do |o|
        o.banner = 'Usage: vm update [--check | --plan] [--macos | --second-mac-only] [--configuration] [--no-pull]'
        o.separator 'Default: update Second Mac, Tart, Softnet, SwiftBar and managed guest helpers/settings together.'
        o.separator 'Keep running sessions and stopped/suspended guests as they are; defer guest changes until the next start.'
        o.separator 'Guest macOS is separate: use --macos. ./update.sh has the same defaults as vm update.'
        o.separator 'Developer packages and coding agents remain managed inside the guest separately.'
        o.on('--check', 'Check the selected update scope; install nothing') { options[:check] = true }
        o.on('--plan', 'Describe the update without network access or changes') { options[:plan] = true }
        o.on('--configuration', 'Apply pending managed guest changes now, then restore its running/stopped state') { options[:configuration] = true }
        o.on('--second-mac-only', 'Update Second Mac code/configuration without upgrading Tart or other dependencies') { options[:second_mac_only] = true }
        o.on('--macos', 'Update only guest macOS and reapply managed settings; no host package upgrades') { options[:macos_only] = true }
        o.on('--no-pull', 'Use current local source without fetching Git changes') { options[:pull] = false }
        o.on('--runtime MODE', 'Select auto, standard or custom Tart for the next start; do not restart') { |v| options[:runtime] = v }
        o.on('--system', '--no-macos', 'Legacy aliases for the default update; guest macOS stays separate') { options[:legacy_system] = true }
        o.on('-h', '--help') { puts o; return }
      end
      remaining = argv.dup
      parser.parse!(remaining)
      raise Error, 'Unexpected update arguments: ' + remaining.join(' ') unless remaining.empty?
      raise Error, 'Use either --check or --plan.' if options[:check] && options[:plan]
      raise Error, 'Use --macos separately from other update scopes or --configuration.' if options[:macos_only] && (options[:second_mac_only] || options[:configuration] || options[:legacy_system])
      raise Error, 'Use --second-mac-only separately from --system/--no-macos.' if options[:second_mac_only] && options[:legacy_system]
      raise Error, 'Runtime must be auto, standard or custom.' if options[:runtime] && !%w[auto standard custom].include?(options[:runtime])
      raise Error, '--runtime changes host configuration; do not combine it with --macos.' if options[:runtime] && options[:macos_only]
      raise Error, 'Retained throwaways keep their saved software and configuration. Update the main VM and create a new copy instead.' if @vm.config['throwaway']
      raise Error, 'Update requires an existing, fully configured VM.' unless @vm.exists? && %w[ready configured].include?(@vm.config['phase'])
      if options[:macos_only]
        if options[:plan]
          puts 'Update Apple-recommended guest macOS, then reapply existing managed privacy and access settings.'
          puts 'Use installed host tools; no Git fetch, Homebrew upgrade or host administrator authorization.'
          puts 'Guest restarts end SSH sessions. Restore the original power state after success; leave failed updates running for recovery.'
          puts 'Developer tools, project dependencies and agents are retained.'
        elsif options[:check]
          check_guest_macos
        else
          perform_macos
        end
        return
      end
      if options[:plan]
        puts "Select #{options[:runtime]} Tart for the next start; do not replace the running executable." if options[:runtime]
        puts(options[:pull] ? 'Refresh a configured Git upstream by fast-forward only.' : 'Use local source without Git fetch or merge.')
        puts 'Update host vm commands and the optional SwiftBar integration.'
        puts 'Rebuild enabled Tart UI patches only when their inputs or installed Tart release change; activate at the next VM start.'
        puts 'Update Tart, Softnet, guest transport, host sharing dependencies and the SwiftBar application.' unless options[:second_mac_only]
        puts 'After a successful VM-tools update, remove obsolete host compiler caches; keep current and referenced builds.' unless options[:second_mac_only]
        puts 'New Tart activates at the next cold start; running sessions keep their current executable.'
        puts 'Refresh changed managed guest settings and installed helpers, including mac-control and optional camera helpers.'
        puts(options[:configuration] ? 'Briefly start a stopped guest if changes are pending; restore its previous running/stopped state.' :
          'Keep the VM running/stopped as it was; a stopped guest receives the latest combined changes at its next managed start.')
        puts 'Leave saved memory suspended. Compare content fingerprints and successful guest receipts; skip already-applied configuration.'
        puts 'Guest macOS is unchanged; use vm update --macos separately. Host macOS/macFUSE use their own updaters.'
        puts 'Developer tools, Python environments, project dependencies, and agent versions are unchanged.'
        return
      end
      source = @vm.config['source_directory']
      if options[:pull]
        RepositoryUpdate.new(source).refresh(check:options[:check])
      else
        puts 'Using local source without Git fetch or merge.'
      end
      if options[:check]
        puts "Requested runtime selection: #{options[:runtime]} (check only; no configuration change)." if options[:runtime]
        check_manager
        check_dependencies unless options[:second_mac_only]
        return
      end
      if source && File.directory?(source) && File.expand_path(source) != File.expand_path('..', __dir__)
        cli = File.join(source, 'lib/cli.rb')
        raise Error, 'Source checkout is incomplete: lib/cli.rb is missing.' unless File.file?(cli)
        exec('/usr/bin/ruby', cli, '--name', @vm.name, 'update', *argv, '--no-pull')
      elsif source && options[:pull]
        # A fast-forward can replace this very file. Reload even when invoked
        # directly from the source checkout; --no-pull prevents recursion.
        exec('/usr/bin/ruby', File.join(__dir__, 'cli.rb'), '--name', @vm.name, 'update', *argv, '--no-pull')
      end
      if options[:runtime]
        require_relative 'runtime'
        Runtime.new(@vm).choose(options[:runtime], build:false)
      end
      perform_manager(configuration:options[:configuration], dependencies:!options[:second_mac_only])
    rescue OptionParser::ParseError => e
      raise Error, e.message
    end

    def check_manager
      @vm.verify_runtime
    rescue Error => e
      puts e.message
    ensure
      if @vm.needs_custom_tart?
        require_relative 'ui-build'
        builder = UIBuild.new(@vm)
        puts(builder.ready? ? 'Tart UI/audio patch build matches current inputs.' : 'Tart UI/audio patch build needs updating; run vm update.')
        report_ui_activation(builder.binary) if builder.ready?
      end
      puts 'Checked host management code only; no guest contact or software installation.'
    end

    def perform_manager(configuration:false, dependencies:false)
      FileUtils.mkdir_p(@vm.state, mode:0700)
      File.open(@vm.file('install.lock'), File::RDWR | File::CREAT, 0600) do |lock|
        raise Error, 'Another VM installation/update is in progress.' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        installer = Installer.new(@vm.config, update:dependencies)
        if dependencies
          puts 'Updating Second Mac and VM tools together. Guest macOS, developer packages and agent versions are retained.'
          installer.host_tools
          NetworkBuild.new(@vm).update
        end
        # Compilation can take minutes. Keep the running VM and its lifecycle
        # lock available during that work; activate only a completed build.
        ui_binary = prepare_ui
        changed = false
        @vm.with_lifecycle_lock do
          installer.bundle(@vm)
          changed = installer.bundle_changed?
          ui_changed = ui_binary && @vm.config['ui_tart'] != ui_binary
          @vm.config['ui_tart'] = ui_binary if ui_binary
          repair = !File.executable?(@vm.file('command')) ||
            (@vm.config['menubar'] && !File.file?(@vm.config['swiftbar_plugin'].to_s))
          if dependencies || changed || repair || ui_changed
            @vm.render_host
            installer.integrations(@vm)
            if @vm.config['menubar']
              require_relative 'menu'
              Menu.new(@vm).install(update_app:dependencies)
            end
          end
          @vm.verify_runtime
          @vm.config['last_manager_update'] = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
          @vm.save
          puts(changed || repair ? 'Second Mac host commands and SwiftBar integration updated.' : 'Second Mac host commands and SwiftBar integration are already current.')
        end
        report_ui_activation(ui_binary) if ui_binary
        guest = GuestUpdate.new(@vm)
        running = @vm.running?
        if (@vm.suspended? || File.file?(@vm.file('suspend.json'))) && !running
          puts 'Guest memory remains suspended. Managed guest changes are deferred until resume; its original Tart executable is retained.'
        elsif running || (configuration && guest.pending?)
          begin
            @vm.start(managed_updates:false) unless running
            guest.synchronize
            refresh_services if running && changed
          ensure
            @vm.stop if !running && @vm.running?
          end
        elsif guest.pending?
          puts 'Guest changes pending; the latest combined configuration will apply at its next managed start.'
        else
          puts 'Managed guest configuration and helpers are already current; the guest remains stopped.'
        end
        if dependencies
          @vm.config['last_successful_update'] = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
          @vm.save
          puts 'Second Mac and VM tools updated; guest macOS, developer packages and agents were retained.'
          clean_build_cache
        end
      end
    end

    def clean_build_cache
      BuildCache.new.clean
    rescue Error, SystemCallError, IOError => e
      # Cache maintenance must not turn a completed update into a failure.
      # The cleaner holds the compiler lock and rechecks runtime references.
      warn "VM tools updated, but compiler-cache cleanup was deferred: #{e.message}"
      warn 'Retry with vm cache clean, or at the next VM-tools update.'
    end

    def prepare_ui
      return unless @vm.needs_custom_tart?
      require_relative 'ui-build'
      builder = UIBuild.new(@vm)
      cached = builder.ready?
      binary = builder.install
      puts(cached ? 'Tart UI/audio patch build is already current; no compilation needed.' : 'Updated Tart UI/audio patch build for the installed release.')
      binary
    end

    def report_ui_activation(binary)
      return unless @vm.running?
      active = JSON.parse(File.read(@vm.file('ui-process.json'))) rescue {}
      return if active['pid'] == @vm.running_pid && active['binary'] == binary
      puts 'Updated UI/audio build is ready for the next VM start; existing sessions continue with their current build.'
    end

    def refresh_services
      require_relative 'credentials'
      Credentials.new(@vm).start
      require_relative 'permissions'
      require_relative 'guest-control'
      require_relative 'network'
      network = Network.new(@vm)
      begin
        live = network.request('op'=>'network-status')['live_switch']
      rescue Error
        live = false
      end
      if live
        network.stop_watcher
        network.start_watcher
      else
        puts 'Live network controller will activate on the next VM start; existing sessions are preserved.'
      end
      Permissions.new(@vm).start_watcher if @vm.config['permissions_auto']
      control = GuestControl.new(@vm)
      if control.enabled?
        control.stop(revoke_session:false)
        control.start
      end
    end

    def check_dependencies
      %w[tart tart-guest-agent].each do |repo|
        body = AgentVM.run('/usr/bin/curl', '--fail', '--silent', '--show-error', '--location',
                           '--proto', '=https', '--proto-redir', '=https', '--max-time', '30',
                           "https://api.github.com/repos/openai/#{repo}/releases/latest", capture:true, timeout:40)
        latest = JSON.parse(body).fetch('tag_name')
        installed = @vm.config[repo.tr('-', '_') + '_version'] || 'unknown'
        puts "#{repo}: installed #{installed}; latest #{latest}"
      end
      puts 'Softnet (installed): ' + AgentVM.run('/opt/homebrew/bin/softnet', '--version', capture:true).strip
      NetworkBuild.new(@vm).check
      if @vm.config['menubar']
        require_relative 'swiftbar'
        body = AgentVM.run('/usr/bin/curl', '--fail', '--silent', '--show-error', '--location',
                           '--proto', '=https', '--proto-redir', '=https', '--max-time', '30',
                           'https://api.github.com/repos/swiftbar/SwiftBar/releases?per_page=30', capture:true, timeout:40)
        selected = SwiftBar.release_asset(JSON.parse(body))
        raise Error, 'No compatible official SwiftBar release found.' unless selected
        release, asset = selected
        build = asset.fetch('name').match(/\.b(\d+)\.zip\z/)[1]
        application = SwiftBar.application
        installed = application ? AgentVM.run('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleVersion',
                                               File.join(application, 'Contents/Info.plist'), capture:true).strip : 'not installed'
        puts "SwiftBar: installed build #{installed}; available #{release.fetch('tag_name')} (build #{build})."
      end
      puts 'vm update refreshes Homebrew metadata and updates Softnet; host macFUSE uses its own updater.'
      puts 'No software was installed and the guest was not contacted. Check guest macOS separately with vm update --macos --check.'
    end

    def check_guest_macos
      running, suspended = @vm.running?, @vm.suspended?
      @vm.start(managed_updates:false) unless running
      puts @vm.ssh('/usr/bin/sw_vers', capture:true)
      puts MacOSUpdate.new(@vm).check
    ensure
      # A read-only catalog scan must not apply pending configuration or leave
      # a previously idle computer consuming CPU/RAM, including on scan errors.
      if !running && @vm.running?
        if suspended
          require_relative 'suspend'
          Suspend.new(@vm).save
        else
          @vm.stop
        end
      end
    end

    def perform_macos
      FileUtils.mkdir_p(@vm.state, mode:0700)
      File.open(@vm.file('install.lock'), File::RDWR | File::CREAT, 0600) do |lock|
        raise Error, 'Another VM installation/update is in progress.' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        running = @vm.running?
        suspended = @vm.suspended?
        @vm.start(managed_updates:false) unless running
        if MacOSUpdate.new(@vm).install
          Installer.new(@vm.config).apply_configuration(@vm, prepare_host:false, integrations:false)
          @vm.config['last_macos_update'] = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
          @vm.save
        end
        # Never shut down in an ensure: a failed/interrupted Apple update may
        # still be finishing installation or need its Recovery environment.
        if suspended
          require_relative 'suspend'
          Suspend.new(@vm).save
        else
          @vm.stop unless running
        end
        puts 'Guest macOS checked. Host dependencies, developer packages and agents were retained.'
      end
    end
  end
end
