require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/install-cli'

class InstallTest < Minitest::Test
  def setup
    @tmp = File.realpath(Dir.mktmpdir('agent-vm-installer-'))
    @old_state = ENV['AGENT_VM_HOME']
    @old_tart = ENV['TART_HOME']
    ENV['AGENT_VM_HOME'] = File.join(@tmp, 'state')
    ENV['TART_HOME'] = File.join(@tmp, 'tart')
  end

  def teardown
    ENV['AGENT_VM_HOME'] = @old_state
    ENV['TART_HOME'] = @old_tart
    FileUtils.remove_entry(@tmp)
  end

  def test_top_level_entry_does_not_reenter_when_loading_swiftbar
    source = File.expand_path('..', __dir__)
    record = File.join(@tmp, 'calls.jsonl')
    fixture = File.join(@tmp, 'stub.rb')
    File.write(fixture, <<~RUBY)
      require #{File.join(source, 'lib/install.rb').dump}
      def AgentVM.run(*args, **options)
        raise "Unexpected external operation: \#{args.first}"
      end
      AgentVM::Installer.prepend(Module.new do
        def run
          File.open(#{record.dump}, 'a') { |f| f.puts(JSON.generate(@config)) }
          raise 'Installer reentered' if File.readlines(#{record.dump}).length > 1
          require #{File.join(source, 'lib/swiftbar.rb').dump}
        end
      end)
    RUBY
    AgentVM.run('/usr/bin/ruby', '-r', fixture, File.join(source, 'lib/install-cli.rb'),
                '--name', 'repeat-test', '--user', 'builder', '--menubar', capture:true)
    calls = File.readlines(record).map { |line| JSON.parse(line) }
    assert_equal 1, calls.length
    assert_equal 'repeat-test', calls.first['name']
    assert_equal 'builder', calls.first['user']
    assert calls.first['menubar']
    refute File.exist?(ENV['AGENT_VM_HOME'])
  end

  def test_update_cannot_create_a_missing_vm
    status = nil
    assert_output('', /update requires an existing managed VM/i) do
      status = AgentVM::InstallCLI.run(['--name', 'missing-vm', '--update'])
    end
    assert_equal 1, status
    refute File.exist?(ENV['AGENT_VM_HOME'])
  end

  def test_host_credentials_are_optional_and_plan_never_requests_a_key
    output, = capture_io { assert_equal 0, AgentVM::InstallCLI.run(%w[--plan --host-credentials openrouter --agents pi]) }
    assert_match(/"credential_relays": \[\s*"openrouter"\s*\]/, output)
    refute File.exist?(ENV['AGENT_VM_HOME'])
    output, = capture_io { assert_equal 0, AgentVM::InstallCLI.run(%w[--plan]) }
    assert_includes output, '"credential_relays": ['
    refute_includes output, '"openrouter"'
  end

  def test_pi_offers_host_credentials_without_enabling_them_in_a_plan
    assert_equal [], planned('--agents', 'pi')['credential_relays']
    assert_equal [], planned('--agents', 'pi', '--host-credentials', 'none')['credential_relays']
    assert_equal [], planned('--agents', 'codex')['credential_relays']
    assert_equal ['openrouter'], planned('--host-credentials', 'openrouter')['credential_relays']
    refute File.exist?(ENV['AGENT_VM_HOME']), 'Plans must not create credentials or other state'
  end

  def installed(*args)
    installer = Object.new
    installer.define_singleton_method(:run) {}
    create = lambda do |config, **_options|
      AgentVM::VM.new(config.merge('phase'=>'preparing')).save
      installer
    end
    AgentVM::Installer.stub(:new, create) do
      capture_io { assert_equal 0, AgentVM::InstallCLI.run(args) }
    end
    AgentVM::VM.load.config
  end

  def test_skipped_pi_key_stays_disabled_on_retry_even_if_host_key_appears
    require_relative '../lib/credentials'
    IO.stub(:console, nil) do
      assert_equal [], installed('--agents', 'pi')['credential_relays']
    end
    refute File.exist?(AgentVM::HostCredentials.path)
    AgentVM::HostCredentials.store('another-vm-key')
    AgentVM::HostCredentials.stub(:offer_pi, -> { flunk 'Retry asked again' }) do
      assert_equal [], installed('--agents', 'pi')['credential_relays']
    end
  end

  def test_explicit_relay_request_can_be_skipped_and_original_command_resumed
    require_relative '../lib/credentials'
    IO.stub(:console, nil) do
      assert_equal [], installed('--agents', 'pi', '--host-credentials', 'openrouter')['credential_relays']
    end
    AgentVM::HostCredentials.store('another-vm-key')
    AgentVM::HostCredentials.stub(:prompt, ->(**_) { flunk 'Retry must preserve the saved opt-out' }) do
      assert_equal [], installed('--agents', 'pi', '--host-credentials', 'openrouter')['credential_relays']
    end
  end

  def test_pi_key_entry_enables_relay_but_explicit_none_never_prompts
    require_relative '../lib/credentials'
    console = Object.new
    console.define_singleton_method(:getpass) { |_| 'new-pi-key' }
    IO.stub(:console, console) do
      assert_equal ['openrouter'], installed('--agents', 'pi')['credential_relays']
    end
    assert_equal 'new-pi-key', AgentVM::HostCredentials.read
    FileUtils.remove_entry(File.join(ENV.fetch('AGENT_VM_HOME'), AgentVM::DEFAULTS.fetch('name')))
    AgentVM::HostCredentials.stub(:offer_pi, -> { flunk 'Explicit none prompted' }) do
      assert_equal [], installed('--agents', 'pi', '--host-credentials', 'none')['credential_relays']
    end
    assert_equal 'new-pi-key', AgentVM::HostCredentials.read
  end

  def test_new_ui_install_enables_guest_control_without_automatic_dialog_approval
    config = planned('--ui')
    assert_equal true, config['guest_control']
    refute config['permissions_auto']
    assert_equal false, planned('--ui', '--no-guest-control-autostart')['guest_control']
  end

  def test_saved_install_grants_survive_resuming_with_pi_and_ui
    vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('agents'=>['pi'], 'ui_enabled'=>true,
      'credential_relays'=>[], 'guest_control'=>false))
    vm.save
    before = File.read(vm.file('config.json'))
    config = planned('--agents', 'pi', '--ui')
    assert_equal [], config['credential_relays']
    assert_equal false, config['guest_control']
    assert_equal before, File.read(vm.file('config.json'))
  end

  def test_release_downloads_are_serialized_across_vm_installations
    cache = File.join(ENV.fetch('AGENT_VM_HOME'), 'downloads')
    FileUtils.mkdir_p(cache)
    installer = AgentVM::Installer.new(AgentVM::DEFAULTS.dup)
    installer.define_singleton_method(:release_unlocked) { |*| 'completed release' }
    File.open(File.join(cache, 'tart.lock'), 'w') do |lock|
      lock.flock(File::LOCK_EX)
      error = assert_raises(AgentVM::Error) { installer.release('tart', 'archive', 'binary') }
      assert_match(/retry when it finishes/, error.message)
    end
    assert_equal 'completed release', installer.release('tart', 'archive', 'binary')
  end

  def test_overlapping_downloads_cannot_remove_each_others_temporary_files
    installer = AgentVM::Installer.new(AgentVM::DEFAULTS.dup)
    path = File.join(@tmp, 'artifact')
    requests = []
    run = lambda do |*args, **|
      temporary = args.last
      requests << temporary
      if requests.length == 1
        installer.download('https://example.invalid/second', path)
      end
      File.write(temporary, 'complete')
      ''
    end
    AgentVM.stub(:run, run) { installer.download('https://example.invalid/first', path) }
    assert_equal 2, requests.uniq.length
    assert_equal 'complete', File.read(path)
    requests.each { |temporary| refute File.exist?(temporary) }
  end

  def test_existing_agent_selection_cannot_trigger_bulk_tool_installation
    vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('name'=>'existing-vm', 'agents'=>['pi']))
    vm.save
    assert_output('', /vm agents add/) do
      assert_equal 1, AgentVM::InstallCLI.run(['--name', vm.name, '--agents', 'pi,codex'])
    end
    assert_equal ['pi'], AgentVM::VM.load(vm.name).config['agents']
  end

  def test_guest_control_autostart_is_explicit_and_enables_guest_ui_for_new_installs
    output, = capture_io { assert_equal 0, AgentVM::InstallCLI.run(%w[--plan --guest-control-autostart --name control-box]) }
    assert_includes output, '"guest_control": true'
    assert_includes output, '"ui_enabled": true'
    output, = capture_io { assert_equal 0, AgentVM::InstallCLI.run(%w[--plan --name control-box]) }
    assert_includes output, '"guest_control": false'
  end

  def planned(*args)
    output, = capture_io { assert_equal 0, AgentVM::InstallCLI.run(['--plan', *args]) }
    JSON.parse(output.split("\nSteps:").first)
  end

  def test_new_installs_detect_linked_folder_once_and_keep_native_readonly_without_driver
    [false, true].each do |ready|
      AgentVM::MacFUSE.stub(:ready?, ready) do
        config = planned('--name', 'new-box')
        assert_equal ready, config['linked_files']
        assert_equal ready ? 3 : 2, AgentVM.share_entries(config).length
        assert_equal true, AgentVM.share_entries(config)[1]['read_only']
      end
    end
    refute File.exist?(ENV['AGENT_VM_HOME'])
  end

  def test_linked_folder_choice_is_explicit_and_resumable
    AgentVM::MacFUSE.stub(:ready?, -> { flunk 'Explicit or saved choices must not be redetected' }) do
      assert_equal false, planned('--no-linked-files')['linked_files']
      assert_equal true, planned('--linked-files')['linked_files']
      assert_equal true, planned('--linked-share', File.join(@tmp, 'links'))['linked_files']
      [false, true].each do |enabled|
        vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('linked_files'=>enabled))
        vm.save
        before = File.read(vm.file('config.json'))
        assert_equal enabled, planned['linked_files']
        assert_equal before, File.read(vm.file('config.json'))
      end
    end
  end

  def test_missing_completed_vm_disk_never_causes_another_install
    vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('name'=>'missing-disk', 'phase'=>'ready'))
    vm.save
    installer = AgentVM::Installer.new(vm.config)
    installer.define_singleton_method(:host_tools) { raise 'Started installing software' }
    error = assert_raises(AgentVM::Error) { installer.run }
    assert_match(/VM disk is missing/, error.message)
  end
  def test_apply_refuses_to_overwrite_staging_during_a_tool_install
    vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('name'=>'busy-setup', 'phase'=>'ready'))
    vm.save
    original = File.read(vm.file('config.json'))
    vm.define_singleton_method(:start) { |**_options| }
    installer = AgentVM::Installer.new(vm.config)
    installer.define_singleton_method(:stage) { |_vm| flunk 'Overwrote active installation staging' }
    vm.with_lifecycle_lock do
      error = assert_raises(AgentVM::Error) { installer.apply_configuration(vm, prepare_host:false) }
      assert_match(/operation is in progress/, error.message)
    end
    assert_equal original, File.read(vm.file('config.json'))
  end

  def test_runtime_refresh_replaces_complete_tree_and_removes_obsolete_files
    source = File.join(@tmp, 'source')
    %w[lib guest packages].each { |dir| AgentVM.write(File.join(source, dir, 'example'), "original\n") }
    %w[agent-vm install.sh bootstrap.sh update.sh].each { |file| AgentVM.write(File.join(source, file), "#!/bin/sh\n", 0755) }
    vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('name'=>'runtime-test'))
    installer = AgentVM::Installer.new(vm.config)
    installer.instance_variable_set(:@source, source)
    installer.bundle(vm)
    inode = File.stat(vm.file('runtime/lib/example')).ino
    installer.bundle(vm)
    refute installer.bundle_changed?
    assert_equal inode, File.stat(vm.file('runtime/lib/example')).ino
    AgentVM.write(vm.file('runtime/lib/obsolete'), 'obsolete')
    File.write(File.join(source, 'lib/example'), "updated\n")
    installer.bundle(vm)
    assert installer.bundle_changed?
    assert_equal "updated\n", File.read(vm.file('runtime/lib/example'))
    refute File.exist?(vm.file('runtime/lib/obsolete'))
    assert_empty Dir.glob(vm.file('.runtime-*'))
    assert_output(/current repository/) { vm.verify_runtime }
  end

  def test_failed_runtime_copy_preserves_working_installation
    vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('name'=>'runtime-failure'))
    AgentVM.write(vm.file('runtime/lib/original'), 'original')
    installer = AgentVM::Installer.new(vm.config)
    FileUtils.stub(:cp_r, lambda { |*| raise IOError, 'copy failed' }) do
      assert_raises(IOError) { installer.bundle(vm) }
    end
    assert_equal 'original', File.read(vm.file('runtime/lib/original'))
    assert_empty Dir.glob(vm.file('.runtime-*'))
  end
end
