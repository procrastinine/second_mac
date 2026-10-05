require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/update'

class RepositoryUpdateTest < Minitest::Test
  def setup
    @tmp = File.realpath(Dir.mktmpdir('agent-vm-update-'))
    @remote, @seed, @checkout = %w[remote seed checkout].map { |part| File.join(@tmp, part) }
    git(@tmp, 'init', '--bare', '--initial-branch=main', @remote)
    git(@tmp, 'clone', @remote, @seed)
    commit(@seed, 'first')
    git(@seed, 'push', '-u', 'origin', 'main')
    git(@tmp, 'clone', @remote, @checkout)
  end
  def teardown
    FileUtils.remove_entry(@tmp)
  end
  def git(directory, *args)
    AgentVM.run('/usr/bin/git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', '-C', directory,
                *args, capture:true, timeout:30)
  end
  def commit(directory, value)
    File.write(File.join(directory, 'value'), value)
    git(directory, 'add', 'value')
    git(directory, 'commit', '-m', value)
  end
  def advance_remote
    commit(@seed, 'second')
    git(@seed, 'push')
  end
  def test_check_fetches_but_only_update_fast_forwards_worktree
    advance_remote
    updater = AgentVM::RepositoryUpdate.new(@checkout)
    assert_output(/1 behind/) { updater.refresh(check:true) }
    assert_equal 'first', File.read(File.join(@checkout, 'value'))
    assert_output(/1 behind/) { updater.refresh }
    assert_equal 'second', File.read(File.join(@checkout, 'value'))
  end
  def test_dirty_worktree_is_not_overwritten
    advance_remote
    File.write(File.join(@checkout, 'value'), 'private edit')
    assert_raises(AgentVM::Error) { AgentVM::RepositoryUpdate.new(@checkout).refresh }
    assert_equal 'private edit', File.read(File.join(@checkout, 'value'))
  end
  def test_divergence_is_not_reset_or_merged
    advance_remote
    commit(@checkout, 'local commit')
    before = git(@checkout, 'rev-parse', 'HEAD')
    assert_output(/1 commits ahead, 1 behind/) do
      assert_raises(AgentVM::Error) { AgentVM::RepositoryUpdate.new(@checkout).refresh }
    end
    assert_equal before, git(@checkout, 'rev-parse', 'HEAD')
  end
  def test_archive_without_upstream_stays_local
    path = File.join(@tmp, 'archive')
    FileUtils.mkdir_p(path)
    assert_output(/No Git upstream/) { AgentVM::RepositoryUpdate.new(path).refresh }
    assert_empty Dir.children(path)
  end
end

class VMUpdateTest < Minitest::Test
  CATALOG = "Software Update found the following new or updated software:\n* Label: macOS update\n\tTitle: macOS, Recommended: YES, Action: restart,\n"
  class FakeVM
    attr_reader :calls, :config, :state
    attr_accessor :catalog, :root_error, :builds, :running
    def initialize(state)
      @state, @calls, @config = state, [], {'user'=>'builder', 'phase'=>'ready'}
      @catalog, @builds = CATALOG, ['old-build', 'old-build', 'new-build']
      @running = true
    end
    def name; 'test-box'; end
    def file(path); File.join(state, path); end
    def password; 'private-test-password'; end
    def exists?; true; end
    def running?; @running; end
    def suspended?; File.file?(file('test-suspended')); end
    def needs_custom_tart?; @config['ui_enabled'] || @config['audio_output']; end
    def running_pid; @running ? 123 : 0; end
    def stop; @calls << :stop; @running = false; end
    def start(**options); @calls << :start; @calls << [:start_options, options]; @running = true; end
    def start_services; @calls << :start_services; end
    def with_lifecycle_lock; yield; end
    def save; @calls << :save; end
    def sync_shares; @calls << :sync_shares; end
    def exclude_backup; @calls << :exclude_backup; end
    def render_host; @calls << :render_host; end
    def verify_runtime; @calls << :verify_runtime; end
    def home; '/Users/builder'; end
    def ssh(*args, **options)
      @calls << [:ssh, args, options]
      return @catalog if args.first == '/usr/sbin/softwareupdate' || args.include?('exec /usr/sbin/softwareupdate --list --product-types macOS 2>&1')
      return @builds.shift || 'new-build' if args.include?('-buildVersion')
      'ok'
    end
    def root(*args, **options)
      @calls << [:root, args, options]
      raise @root_error if @root_error
    end
    def wait_for(*)
      3.times do
        @calls << :boot_probe
        return if yield
      end
      raise AgentVM::Error, 'No updated build appeared'
    end
  end

  def setup
    @tmp = File.realpath(Dir.mktmpdir('agent-vm-update-flow-'))
    @vm = FakeVM.new(@tmp)
    @previous_state_root = ENV['AGENT_VM_HOME']
    ENV['AGENT_VM_HOME'] = File.join(@tmp, 'management')
    @cache = AgentVM::BuildCache.new
    @obsolete_cache = File.join(@cache.root, 'source-2.40.0', '.build')
    @current_cache = File.join(@cache.root, 'source-2.40.1', '.build')
    [@obsolete_cache, @current_cache].each { |path| AgentVM.write(File.join(path, 'object'), 'compiler output') }
    AgentVM.json_write(File.join(AgentVM.state_root, 'test-box/config.json'), {'tart_version'=>'2.40.1'})
  end
  def teardown
    ENV['AGENT_VM_HOME'] = @previous_state_root
    FileUtils.remove_entry(@tmp)
  end

  def with_manager_dependencies
    installer = Object.new
    installer.define_singleton_method(:host_tools) { }
    installer.define_singleton_method(:bundle) { |_| }
    installer.define_singleton_method(:bundle_changed?) { false }
    installer.define_singleton_method(:integrations) { |_| }
    guest = Object.new
    guest.define_singleton_method(:pending?) { true }
    guest.define_singleton_method(:synchronize) { }
    AgentVM::Installer.stub(:new, installer) do
      AgentVM::GuestUpdate.stub(:new, guest) { yield installer, guest }
    end
  end

  def test_plan_does_not_touch_vm_or_run_commands
    AgentVM.stub(:run, lambda { |*| raise 'Plan ran an external command' }) do
      assert_output(/Developer tools.*unchanged/) { AgentVM::Update.new(@vm).command(['--plan']) }
    end
    assert_empty @vm.calls
    assert File.directory?(@obsolete_cache)
  end
  def test_macos_check_restores_stopped_state_without_applying_configuration
    @vm.running = false
    capture_io { AgentVM::Update.new(@vm).command(['--macos', '--check']) }
    refute @vm.running?
    assert_includes @vm.calls, [:start_options, {managed_updates:false}]
    assert_equal :stop, @vm.calls.last
    refute @vm.calls.any? { |call| call.is_a?(Array) && call.first == :root }
  end
  def test_failed_catalog_scan_still_restores_previously_stopped_guest
    @vm.running = false
    updater = Object.new
    updater.define_singleton_method(:check) { raise AgentVM::Error, 'Catalog unavailable' }
    AgentVM::MacOSUpdate.stub(:new, updater) do
      capture_io { assert_raises(AgentVM::Error) { AgentVM::Update.new(@vm).check_guest_macos } }
    end
    refute @vm.running?
    assert_equal :stop, @vm.calls.last
  end
  def test_macos_check_returns_saved_memory_to_suspended_state
    @vm.running = false
    File.write(@vm.file('test-suspended'), 'saved')
    calls = @vm.calls
    checkpoint = Object.new
    checkpoint.define_singleton_method(:save) { calls << :suspend }
    require_relative '../lib/suspend'
    AgentVM::Suspend.stub(:new, checkpoint) do
      capture_io { AgentVM::Update.new(@vm).command(['--macos', '--check']) }
    end
    assert_equal :suspend, calls.last
    refute_includes calls, :stop
  end
  def test_default_update_keeps_a_stopped_guest_stopped_and_defers_changes
    calls = []
    @vm.config['source_mode'] = 'local'
    @vm.config['menubar'] = true
    @vm.running = false
    installer = Object.new
    installer.define_singleton_method(:host_tools) { calls << :host_tools }
    installer.define_singleton_method(:bundle) { |_vm| calls << :bundle }
    installer.define_singleton_method(:bundle_changed?) { true }
    installer.define_singleton_method(:integrations) { |_vm| calls << :integrations }
    menu = Object.new
    menu.define_singleton_method(:install) { |**options| calls << [:menu, options] }
    guest = Object.new
    guest.define_singleton_method(:pending?) { true }
    require_relative '../lib/menu'
    AgentVM::RepositoryUpdate.stub(:new, lambda { |*| flunk 'Local source mode tried to pull' }) do
      AgentVM::Installer.stub(:new, installer) do
        AgentVM::Menu.stub(:new, menu) do
          AgentVM::GuestUpdate.stub(:new, guest) do
            assert_output(/latest combined configuration/) { AgentVM::Update.new(@vm).command([]) }
          end
        end
      end
    end
    assert_equal [:host_tools, :bundle, :integrations, [:menu, {update_app:true}]], calls
    assert_equal [:render_host, :verify_runtime, :save, :save], @vm.calls
    assert @vm.config['last_manager_update']
    assert @vm.config['last_successful_update']
    refute File.exist?(@obsolete_cache)
    assert File.directory?(@current_cache)
  end
  def test_busy_compiler_defers_cleanup_without_failing_update_and_retry_removes_old_cache
    @vm.config['source_mode'] = 'local'
    @vm.running = false
    with_manager_dependencies do
      File.open(File.join(@cache.root, 'source-2.40.0.lock'), File::RDWR | File::CREAT, 0600) do |lock|
        assert lock.flock(File::LOCK_EX | File::LOCK_NB)
        assert_output(/VM tools updated;/, /cleanup was deferred: A compiler is using this release.*vm cache clean/m) do
          AgentVM::Update.new(@vm).command([])
        end
        assert @vm.config['last_successful_update']
        assert File.directory?(@obsolete_cache)
      end
      assert_output(/Removed .*obsolete compiler intermediates/, '') { AgentVM::Update.new(@vm).command([]) }
    end
    refute File.exist?(@obsolete_cache)
    assert File.directory?(@current_cache)
    refute_includes @vm.calls, :start
    refute_includes @vm.calls, :stop
  end
  def test_failed_guest_synchronization_keeps_compiler_caches_for_retry
    with_manager_dependencies do |_installer, guest|
      guest.define_singleton_method(:synchronize) { raise AgentVM::Error, 'Helper update interrupted' }
      capture_io { assert_raises(AgentVM::Error) { AgentVM::Update.new(@vm).command(['--no-pull']) } }
    end
    assert File.directory?(@obsolete_cache)
    assert File.directory?(@current_cache)
    refute @vm.config['last_successful_update']
    assert @vm.running?
  end
  def test_source_managed_check_has_no_git_or_guest_operations
    @vm.config['source_mode'] = 'local'
    AgentVM::RepositoryUpdate.stub(:new, lambda { |*| flunk 'Local source mode tried to fetch' }) do
      assert_output(/no guest contact/) { AgentVM::Update.new(@vm).command(['--second-mac-only', '--check']) }
    end
    assert_equal [:verify_runtime], @vm.calls
  end
  def test_default_check_includes_vm_releases_without_contacting_guest_or_installing
    @vm.config['source_mode'] = 'local'
    @vm.config['menubar'] = true
    require_relative '../lib/swiftbar'
    releases = [{'tag_name'=>'current-menu', 'published_at'=>'2026-10-01', 'assets'=>[{'name'=>'SwiftBar.current.b623.zip'}]}]
    commands = []
    AgentVM.stub(:run, lambda { |*args, **_options|
      commands << args
      if args.first == '/usr/bin/curl'
        args.last.include?('swiftbar/SwiftBar') ? JSON.generate(releases) : JSON.generate('tag_name'=>'current-release')
      elsif args == ['/opt/homebrew/bin/softnet', '--version']
        'installed-version'
      else
        flunk "Unexpected update-check command: #{args.inspect}"
      end
    }) do
      output = nil
      AgentVM::SwiftBar.stub(:application, nil) do
        output, = capture_io { AgentVM::Update.new(@vm).command(['--check']) }
      end
      assert_includes output, 'tart: installed'
      assert_includes output, 'tart-guest-agent: installed'
      assert_includes output, 'SwiftBar: installed build not installed; available current-menu'
      assert_includes output, 'Check guest macOS separately'
    end
    assert_equal [:verify_runtime], @vm.calls
    assert_equal 3, commands.count { |args| args.first == '/usr/bin/curl' }
    assert File.directory?(@obsolete_cache)
  end
  def test_configuration_update_preserves_power_state_and_skips_unchanged_stopped_guest
    [false, true].each do |running|
      @vm.running = running
      @vm.config['source_mode'] = 'local'
      installer = Object.new
      installer.define_singleton_method(:bundle) { |_| }
      installer.define_singleton_method(:bundle_changed?) { false }
      installer.define_singleton_method(:integrations) { |_| }
      guest = Object.new
      calls = @vm.calls
      pending = true
      guest.define_singleton_method(:pending?) { pending }
      guest.define_singleton_method(:synchronize) { calls << :guest_configuration }
      AgentVM::Installer.stub(:new, installer) do
        AgentVM::GuestUpdate.stub(:new, guest) do
          capture_io { AgentVM::Update.new(@vm).command(['--second-mac-only', '--configuration']) }
          assert_equal running, @vm.running?
          assert_includes calls, :guest_configuration
          assert_equal running ? 0 : 1, calls.count(:start)
          calls.clear
          unless running
            guest.define_singleton_method(:synchronize) { raise AgentVM::Error, 'configuration failed' }
            capture_io { assert_raises(AgentVM::Error) { AgentVM::Update.new(@vm).command(['--second-mac-only', '--configuration']) } }
            refute @vm.running?, 'a failed managed update must restore a previously stopped VM'
            calls.clear
          end
          @vm.running = false
          pending = false
          capture_io { AgentVM::Update.new(@vm).command(['--second-mac-only', '--configuration']) }
          refute_includes calls, :start
          refute_includes calls, :guest_configuration
        end
      end
      calls.clear
    end
    assert File.directory?(@obsolete_cache)
  end
  def test_default_and_legacy_aliases_include_dependencies_but_never_macos
    updater = AgentVM::Update.new(@vm)
    calls = []
    updater.define_singleton_method(:perform_manager) { |**options| calls << options }
    AgentVM::MacOSUpdate.stub(:new, ->(*) { flunk 'Only --macos may access the Apple updater' }) do
      [[], ['--system'], ['--no-macos'], ['--system', '--no-macos'], ['--configuration'], ['--second-mac-only']].each do |flags|
        capture_io { updater.command([*flags, '--no-pull']) }
      end
    end
    assert_equal [true, true, true, true, true, false], calls.map { |options| options[:dependencies] }
    assert_equal [false, false, false, false, true, false], calls.map { |options| options[:configuration] }
    assert_empty @vm.calls
  end

  def test_network_library_updates_only_with_dependencies_and_never_restarts_guest
    @vm.config['source_mode'] = 'local'
    calls = []
    network = Object.new
    network.define_singleton_method(:update) { calls << :network_dependencies }
    with_manager_dependencies do
      AgentVM::NetworkBuild.stub(:new, network) do
        capture_io { AgentVM::Update.new(@vm).command(['--second-mac-only']) }
        assert_empty calls
        capture_io { AgentVM::Update.new(@vm).command([]) }
        assert_equal [:network_dependencies], calls
      end
    end
    refute_includes @vm.calls, :start
    refute_includes @vm.calls, :stop
  end

  def test_configuration_update_never_wakes_or_shuts_down_saved_guest_memory
    @vm.running = false
    @vm.config['source_mode'] = 'local'
    File.write(@vm.file('test-suspended'), 'saved')
    installer = Object.new
    installer.define_singleton_method(:host_tools) { }
    installer.define_singleton_method(:bundle) { |_| }
    installer.define_singleton_method(:bundle_changed?) { false }
    installer.define_singleton_method(:integrations) { |_| }
    guest = Object.new
    guest.define_singleton_method(:pending?) { true }
    guest.define_singleton_method(:synchronize) { raise 'Suspended guest was changed' }
    AgentVM::Installer.stub(:new, installer) do
      AgentVM::GuestUpdate.stub(:new, guest) do
        assert_output(/memory remains suspended/) { AgentVM::Update.new(@vm).command(['--configuration']) }
      end
    end
    refute_includes @vm.calls, :start
    refute_includes @vm.calls, :stop
    assert @vm.suspended?
  end

  def test_guest_only_os_update_never_upgrades_host_or_fetches_git_and_restores_power_state
    calls = []
    installer = Object.new
    installer.define_singleton_method(:host_tools) { flunk 'Guest-only update attempted host package maintenance' }
    installer.define_singleton_method(:apply_configuration) { |_, **opts| calls << opts }
    macos = Object.new
    macos.define_singleton_method(:install) { true }
    [true, false].each do |running|
      @vm.running = running
      AgentVM::RepositoryUpdate.stub(:new, ->(*) { flunk 'Guest-only update fetched Git' }) do
        AgentVM::Installer.stub(:new, installer) do
          AgentVM::MacOSUpdate.stub(:new, macos) do
            assert_output(/Host dependencies.*retained/) { AgentVM::Update.new(@vm).command(['--macos']) }
          end
        end
      end
      assert_equal running, @vm.running?
      assert_equal({prepare_host:false, integrations:false}, calls.last)
      assert @vm.config['last_macos_update']
      assert File.directory?(@obsolete_cache)
    end
    @vm.running = false
    macos.define_singleton_method(:install) { raise AgentVM::Error, 'Apple update interrupted' }
    AgentVM::MacOSUpdate.stub(:new, macos) do
      assert_raises(AgentVM::Error) { AgentVM::Update.new(@vm).command(['--macos']) }
    end
    assert @vm.running?, 'failed Apple installation must remain available for recovery'
  end

  def test_guest_only_os_plan_is_read_only_and_conflicting_scopes_fail
    AgentVM.stub(:run, ->(*) { flunk 'Plan ran an external command' }) do
      assert_output(/no Git fetch.*host administrator/) { AgentVM::Update.new(@vm).command(['--macos', '--plan']) }
    end
    assert_empty @vm.calls
    %w[--system --no-macos --second-mac-only --configuration].each do |flag|
      [[flag, '--macos'], ['--macos', flag]].each do |args|
        assert_raises(AgentVM::Error) { AgentVM::Update.new(@vm).command(args) }
      end
    end
    assert_empty @vm.calls
  end
  def test_ui_patch_update_selects_completed_build_but_preserves_running_sessions
    require_relative '../lib/ui-build'
    @vm.config.merge!('ui_enabled'=>true, 'ui_tart'=>'/previous/tart', 'source_mode'=>'local')
    builder = Object.new
    builder.define_singleton_method(:ready?) { false }
    builder.define_singleton_method(:install) { '/updated/tart' }
    installer = Object.new
    installer.define_singleton_method(:bundle) { |_| }
    installer.define_singleton_method(:bundle_changed?) { false }
    installer.define_singleton_method(:integrations) { |_| }
    guest = Object.new
    guest.define_singleton_method(:synchronize) { }
    updater = AgentVM::Update.new(@vm)
    AgentVM::UIBuild.stub(:new, builder) do
      AgentVM::Installer.stub(:new, installer) do
        AgentVM::GuestUpdate.stub(:new, guest) do
          assert_output(/next VM start.*existing sessions/) { updater.command(['--second-mac-only', '--configuration']) }
        end
      end
    end
    assert_equal '/updated/tart', @vm.config['ui_tart']
    refute_includes @vm.calls, :stop
    refute_includes @vm.calls, :start
    AgentVM.json_write(@vm.file('ui-process.json'), {'pid'=>123, 'binary'=>'/updated/tart'})
    assert_output('') { updater.report_ui_activation('/updated/tart') }
  end
  def test_disabled_ui_never_downloads_or_compiles_tart
    require_relative '../lib/ui-build'
    AgentVM::UIBuild.stub(:new, ->(*) { flunk 'Disabled UI must not build Tart' }) do
      assert_nil AgentVM::Update.new(@vm).prepare_ui
    end
  end
  def test_configuration_path_uses_no_guest_package_installer
    @vm.config['sharing'] = 'none'
    installer = AgentVM::Installer.new(@vm.config)
    installer.define_singleton_method(:stage) { |vm, **options| vm.calls << [:stage, options] }
    installer.define_singleton_method(:integrations) { |vm| vm.calls << :integrations }
    receipt = Object.new
    receipt.define_singleton_method(:record_configuration) {}
    AgentVM::GuestUpdate.stub(:new, receipt) do
      assert_output(/Applied/) { installer.apply_configuration(@vm, prepare_host:false) }
    end
    assert_includes @vm.calls, [:stage, {bootstrap:false}]
    commands = @vm.calls.grep(Array).select { |call| %i[ssh root].include?(call[0]) }.map { |call| call[1].join(' ') }
    assert commands.any? { |line| line.include?('guest/apply-config.sh') }
    assert commands.any? { |line| line.include?('guest/finalize.rb') }
    refute commands.any? { |line| line.match?(/install-tools|install-agents|brew (?:upgrade|bundle)|pip install|npm install/) }
  end
  def test_default_update_keeps_running_guest_and_synchronizes_without_os_or_package_installers
    calls = []
    @vm.config['source_mode'] = 'local'
    installer = Object.new
    installer.define_singleton_method(:host_tools) { calls << :host_tools }
    installer.define_singleton_method(:bundle) { |_| calls << :bundle }
    installer.define_singleton_method(:bundle_changed?) { false }
    installer.define_singleton_method(:integrations) { |_| calls << :integrations }
    guest = Object.new
    guest.define_singleton_method(:synchronize) { calls << :configuration }
    AgentVM::Installer.stub(:new, installer) do
      AgentVM::GuestUpdate.stub(:new, guest) do
        AgentVM::MacOSUpdate.stub(:new, ->(*) { flunk 'Default update contacted macOS updater' }) do
          assert_output(/guest macOS, developer packages and agents were retained/) { AgentVM::Update.new(@vm).command([]) }
        end
      end
    end
    assert_equal [:host_tools, :bundle, :integrations, :configuration], calls
    refute_includes @vm.calls, :stop
    refute_includes @vm.calls, :start
  end
  def test_host_update_failure_preserves_an_already_running_guest
    installer = Object.new
    installer.define_singleton_method(:host_tools) { raise AgentVM::Error, 'Authorization canceled' }
    AgentVM::Installer.stub(:new, installer) do
      capture_io { assert_raises(AgentVM::Error) { AgentVM::Update.new(@vm).command(['--no-pull']) } }
    end
    assert @vm.running?
    refute_includes @vm.calls, :stop
    refute @vm.config['last_successful_update']
    assert File.directory?(@obsolete_cache)
  end
  def test_macos_password_uses_stdin_and_reboot_requires_changed_build
    @vm.root_error = AgentVM::Error.new('ssh failed (255): connection closed')
    assert_output(/ok/) { assert AgentVM::MacOSUpdate.new(@vm).install }
    command = @vm.calls.find { |call| call.is_a?(Array) && call.first == :root }
    refute_includes command[1], @vm.password
    assert_includes command[1], '--stdinpass'
    assert_includes command[1], '--os-only'
    assert_equal @vm.password + "\n", command[2][:input]
    assert_equal 2, @vm.calls.count(:boot_probe)
  end
  def test_macos_auth_failure_is_not_treated_as_success_or_retried
    @vm.root_error = AgentVM::Error.new('ssh failed (1): authentication failed')
    assert_output(/Software Update/) do
      assert_raises(AgentVM::Error) { AgentVM::MacOSUpdate.new(@vm).install }
    end
    refute_includes @vm.calls, :boot_probe
  end
  def test_up_to_date_and_unrecognized_catalogs_do_not_install
    @vm.catalog = 'No new software available.'
    assert_output(/No new software/) { refute AgentVM::MacOSUpdate.new(@vm).install }
    @vm.catalog = 'Unexpected response'
    assert_output(/Unexpected/) do
      assert_raises(AgentVM::Error) { AgentVM::MacOSUpdate.new(@vm).install }
    end
    refute @vm.calls.grep(Array).any? { |call| call.first == :root }
  end
  def test_successful_up_to_date_notice_on_stderr_is_not_lost
    script = File.join(@tmp, 'softwareupdate')
    AgentVM.write(script, "#!/bin/sh\nprintf 'Software Update Tool\\n'\nprintf 'No new software available.\\n' >&2\n", 0700)
    @vm.define_singleton_method(:ssh) do |*args, **options|
      args = args.map { |arg| arg.sub('/usr/sbin/softwareupdate', Shellwords.escape(script)) }
      AgentVM.run(*args, **options)
    end
    assert_output(/No new software available/) { refute AgentVM::MacOSUpdate.new(@vm).install }
    refute @vm.calls.any? { |call| call.is_a?(Array) && call.first == :root }
  end
end
