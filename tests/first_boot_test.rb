require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/first-boot'
require_relative '../lib/gui'

class FirstBootTest < Minitest::Test
  def setup
    @previous = ENV['AGENT_VM_HOME']
    @directory = File.realpath(Dir.mktmpdir('second-mac-first-boot-'))
    ENV['AGENT_VM_HOME'] = @directory
    @config = AgentVM::DEFAULTS.merge('name'=>'setup-box', 'user'=>'builder', 'phase'=>'creating',
      'sharing'=>'none', 'tart'=>'/fixture/tart',
      'restore_image'=>{'url'=>'https://example.invalid/restore.ipsw', 'version'=>'27.0.1', 'build'=>'26A434'})
  end

  def teardown
    ENV['AGENT_VM_HOME'] = @previous
    FileUtils.remove_entry(@directory)
  end

  def test_first_boot_capability_matrix_including_older_sdk_and_future_hosts
    [
      ['26.0', '26.0', 'auto', true, 'manual'],
      ['26.6', '27.0', 'auto', true, 'manual'],
      ['27.0', '26.0', 'auto', true, 'manual'],
      ['27.0', '27.0', 'auto', true, 'native'],
      ['28.0', '28.0', 'auto', true, 'native'],
      ['27.0', '27.0', 'manual', true, 'manual'],
      ['27.0', nil, 'auto', true, 'manual'],
      ['27.0', '27.0', 'auto', false, 'manual']
    ].each_with_index do |(host, guest, setup, supported, expected), index|
      config = @config.merge('name'=>"setup-#{index}", 'setup'=>setup)
      config['restore_image'] = guest && config['restore_image'].merge('version'=>guest)
      vm = AgentVM::VM.new(config)
      calls = []
      runner = lambda do |*args, **|
        calls << args
        case args
        when ['/usr/bin/sw_vers', '-productVersion'] then host
        when ['/fixture/tart', 'run', '--help'] then supported ? '--provisioning-opts' : '--no-graphics'
        else flunk "Unexpected command #{args.inspect}"
        end
      end
      AgentVM.stub(:run, runner) { assert_equal expected, AgentVM::FirstBoot.new(vm).prepare, config.inspect }
      assert_equal expected, AgentVM::VM.load(vm.name).config['setup_method']
      assert_equal 1, calls.length if host.start_with?('26.') || setup == 'manual'
    end
  end

  def test_checks_actual_custom_executable_and_reuses_saved_setup_on_resume
    vm = AgentVM::VM.new(@config.merge('runtime_mode'=>'custom', 'ui_tart'=>'/fixture/custom-tart'))
    calls = []
    AgentVM.stub(:run, lambda { |*args, **| calls << args; args.first == '/usr/bin/sw_vers' ? '27.0' : '--no-graphics' }) do
      assert_equal 'manual', AgentVM::FirstBoot.new(vm).prepare
    end
    assert_includes calls, ['/fixture/custom-tart', 'run', '--help']
    resumed = AgentVM::VM.load(vm.name)
    AgentVM.stub(:run, ->(*) { flunk 'Re-selected setup instead of resuming' }) do
      assert_equal 'manual', AgentVM::FirstBoot.new(resumed).prepare
    end
  end

  def test_legacy_in_progress_account_is_never_replaced_with_a_new_manual_password
    vm = AgentVM::VM.new(@config.merge('phase'=>'bootstrap', 'restore_image'=>nil))
    AgentVM.write(vm.file('admin-password'), "original credential\n")
    AgentVM.stub(:run, ->(*args, **) { args.first == '/usr/bin/sw_vers' ? '27.0' : '--provisioning-opts' }) do
      assert_equal 'native', AgentVM::FirstBoot.new(vm).prepare
    end
    assert_equal "original credential\n", File.read(vm.file('admin-password'))
    another = AgentVM::VM.new(@config.merge('name'=>'other-box', 'phase'=>'bootstrap'))
    AgentVM.stub(:run, ->(*) { '26.0' }) do
      assert_raises(AgentVM::Error) { AgentVM::FirstBoot.new(another).prepare }
    end
    refute another.config.key?('setup_method')
  end

  def test_guided_launch_opens_desktop_and_resume_does_not_restart_it
    vm = AgentVM::VM.new(@config.merge('phase'=>'bootstrap', 'setup_method'=>'manual'))
    launches = []
    vm.define_singleton_method(:running?) { !launches.empty? }
    vm.define_singleton_method(:launch) { |**options| launches << options }
    window = Object.new
    window.define_singleton_method(:active?) { false }
    AgentVM::GUI.stub(:new, window) do
      2.times { assert_output(/Create the account with account name builder/) { AgentVM::FirstBoot.new(vm).launch } }
    end
    assert_equal [{graphics:true}], launches
  end

  def test_guided_launch_never_passes_native_provisioning_or_exposes_password
    vm = AgentVM::VM.new(@config.merge('phase'=>'bootstrap', 'setup_method'=>'manual'))
    vm.define_singleton_method(:password) { flunk 'Read a placeholder password before manual setup' }
    AgentVM.stub(:run, ->(*) { '' }) do
      args = vm.run_args(graphics:true)
      refute args.any? { |arg| arg.start_with?('--provisioning-opts') }
      refute_includes args, '--no-graphics'
      assert_includes args, '--no-clipboard'
      assert_includes args, '--net-softnet-block=out @host'
    end
  end

  def test_native_launch_preserves_automatic_account_arguments
    vm = AgentVM::VM.new(@config.merge('phase'=>'bootstrap', 'setup_method'=>'native'))
    AgentVM.write(vm.file('admin-password'), "fixture-password\n")
    AgentVM.stub(:run, ->(*) { '' }) do
      args = vm.run_args
      assert args.any? { |arg| arg.start_with?('--provisioning-opts=') && arg.include?('username=builder') }
      assert_includes args, '--no-graphics'
    end
  end

  def test_guided_password_is_private_and_not_asked_again_after_success
    vm = AgentVM::VM.new(@config.merge('phase'=>'bootstrap', 'setup_method'=>'manual'))
    boot = AgentVM::FirstBoot.new(vm)
    boot.define_singleton_method(:password_from_console) { 'fixture-secret' }
    commands = []
    AgentVM.stub(:run, lambda { |*args, **options| commands << args; assert options[:capture]; 'Guest SSH key installed.' }) do
      assert_output(/Guest SSH key installed/) { boot.authenticate('192.0.2.10', 22) }
      resumed = AgentVM::FirstBoot.new(AgentVM::VM.load(vm.name))
      resumed.define_singleton_method(:password_from_console) { flunk 'Asked again for confirmed password' }
      capture_io { resumed.authenticate('192.0.2.10', 22) }
    end
    assert_equal "fixture-secret\n", File.read(vm.file('admin-password'))
    assert_equal 0600, File.stat(vm.file('admin-password')).mode & 0777
    refute_includes commands.flatten.join(' '), 'fixture-secret'
    refute_includes File.read(vm.file('config.json')), 'fixture-secret'
    assert AgentVM::VM.load(vm.name).config['manual_password_confirmed']
  end

  def test_rejected_password_can_be_reentered_without_resetting_guest_or_ssh_key
    vm = AgentVM::VM.new(@config.merge('phase'=>'bootstrap', 'setup_method'=>'manual', 'manual_password_confirmed'=>true))
    vm.save
    AgentVM.write(vm.file('id_ed25519'), 'unchanged key')
    boot = AgentVM::FirstBoot.new(vm)
    boot.define_singleton_method(:password_from_console) { flunk 'Asked before trying saved password' }
    AgentVM.stub(:run, ->(*) { raise AgentVM::Error, 'Guest rejected the bootstrap password.' }) do
      error = assert_raises(AgentVM::Error) { boot.authenticate('192.0.2.10', 22) }
      assert_includes error.message, 'enter its password again'
    end
    refute AgentVM::VM.load(vm.name).config['manual_password_confirmed']
    assert_equal 'unchanged key', File.read(vm.file('id_ed25519'))
  end

  def test_unattended_manual_setup_does_not_fall_back_to_insecure_password_input
    boot = AgentVM::FirstBoot.new(AgentVM::VM.new(@config.merge('setup_method'=>'manual')))
    IO.stub(:console, nil) do
      error = assert_raises(AgentVM::Error) { boot.authenticate('192.0.2.10', 22) }
      assert_includes error.message, 'terminal'
    end
    refute File.exist?(File.join(@directory, 'setup-box/admin-password'))
  end
end
