require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/throwaway'
require_relative '../lib/shared'

class ThrowawayTest < Minitest::Test
  def setup
    @tmp = File.realpath(Dir.mktmpdir('agent-vm-throwaway-'))
    @old_state, @old_tart = ENV['AGENT_VM_HOME'], ENV['TART_HOME']
    ENV['AGENT_VM_HOME'], ENV['TART_HOME'] = File.join(@tmp, 'state'), File.join(@tmp, 'tart')
    @source = AgentVM::VM.new(AgentVM::DEFAULTS.merge('name'=>'source-box', 'user'=>'builder', 'phase'=>'ready',
      'tart'=>'/fake/tart', 'share'=>File.join(@tmp, 'host-share'), 'host_label'=>'local.agent-vm.source-box', 'menubar'=>true))
    FileUtils.mkdir_p(@source.tart_directory)
    FileUtils.mkdir_p(@source.config['share'])
    %w[config.json disk.img nvram.bin].each { |name| File.write(File.join(@source.tart_directory, name), name + '-original') }
    %w[admin-password id_ed25519 id_ed25519.pub].each { |name| AgentVM.write(@source.file(name), 'fixture-' + name) }
    AgentVM.write(@source.file('known-hosts'), "source-box ssh-ed25519 fixture\n")
    AgentVM.json_write(@source.file('ports.json'), [{'direction'=>'host', 'from'=>8080, 'to'=>8080}])
    AgentVM.write(File.join(AgentVM.state_root, 'default'), @source.name)
    @source.save
    @runner = AgentVM::Throwaway.new(@source.name)
    @calls, @exclusions = [], []
  end

  def teardown
    ENV['AGENT_VM_HOME'], ENV['TART_HOME'] = @old_state, @old_tart
    FileUtils.remove_entry(@tmp)
  end

  def create
    calls, exclusions = @calls, @exclusions
    constructor = lambda do |config, **options|
      vm = AgentVM::VM.allocate
      vm.send(:initialize, config, **options)
      vm.define_singleton_method(:exclude_backup) { |*paths| exclusions << paths }
      vm
    end
    vm = nil
    AgentVM::VM.stub(:new, constructor) do
      AgentVM.stub(:run, lambda { |*args, **_options| calls << args; '' }) do
        capture_io { vm = @runner.create }
      end
    end
    vm
  end

  def test_a_mistyped_command_is_not_read_as_a_missing_script
    error = assert_raises(AgentVM::Error) { @runner.command(['lst']) }
    assert_match(/Unknown throwaway command: lst\./, error.message)
    error = assert_raises(AgentVM::Error) { @runner.command(['./missing.sh']) }
    assert_match(/Script must be a readable local file: .\/missing.sh/, error.message)
    output, = capture_io { assert_equal 0, @runner.command(['ls']) }
    assert_match(/No retained throwaways/, output)
  end

  def test_cow_copy_retains_data_but_never_inherits_host_grants
    @source.config['credential_relays'] = ['openrouter']
    AgentVM.json_write(@source.file('model-relay-grant.json'), {'token'=>'fixture'})
    @source.config['guest_control'] = true
    @source.config['permissions_auto'] = true
    @source.config['microphone'] = true
    @source.config['camera_obs'] = true
    @source.save
    AgentVM.json_write(@source.file('guest-control.json'), {'token'=>'fixture'})
    vm = create
    assert_empty vm.config['credential_relays']
    assert vm.config['credential_relay_cleanup']
    refute File.exist?(vm.file('model-relay-grant.json'))
    assert_match(/\A[0-9a-f]{8}\z/, vm.config['throwaway']['id'])
    assert_equal 'ready', vm.config['phase']
    assert_equal vm.file('runtime'), vm.config['source_directory']
    assert_equal 'local', vm.config['source_mode']
    assert_equal 'none', vm.config['sharing']
    refute vm.config['menubar']
    refute vm.config['integrations']
    refute vm.config['guest_control']
    refute vm.config['permissions_auto']
    refute vm.config['microphone']
    refute vm.config['camera_obs']
    refute File.exist?(vm.file('guest-control.json'))
    refute vm.config['throwaway']['guest_configured']
    refute File.exist?(vm.file('ports.json'))
    refute File.exist?(vm.config['share'])
    assert_equal 'source-box', File.read(File.join(AgentVM.state_root, 'default'))
    assert_equal @source.password, vm.password
    assert File.read(vm.file('known-hosts')).start_with?(vm.name + ' ')
    assert_equal [[vm.tart_directory, vm.state]], @exclusions
    assert @calls.any? { |args| args.include?('--random-mac') && args.include?('--random-serial') }
    refute @calls.any? { |args| (args & %w[create pull clone curl]).any? }
    original, copied = [@source, vm].map { |v| File.join(v.tart_directory, 'disk.img') }
    refute_equal File.stat(original).ino, File.stat(copied).ino
    assert_equal File.read(original), File.read(copied)
    File.write(copied, 'throwaway changes')
    assert_equal 'disk.img-original', File.read(original)
    File.write(original, 'later source changes')
    assert_equal 'throwaway changes', File.read(copied)
    args = vm.run_args
    assert_includes args, '--no-audio'
    refute args.any? { |arg| arg.start_with?('--dir=', '--provisioning-opts=') }
    assert args.any? { |arg| arg.start_with?('--net-softnet-block=@host,') }
    assert_empty AgentVM.shares(vm.config)
    assert_equal vm.name, @runner.find(vm.config['throwaway']['id']).name
    assert_output(/saved source manifest/) { vm.verify_runtime }
    output, = capture_io { @runner.list(json:true) }
    assert_equal vm.config['throwaway']['id'], JSON.parse(output).first['id']
  end

  def test_direct_commands_use_the_saved_copy_runtime_and_updates_are_refused
    vm = create
    AgentVM.write(vm.file('runtime/lib/cli.rb'), "puts 'SAVED_COPY_RUNTIME'\nputs ARGV.join(' ')\n")
    cli = File.expand_path('../agent-vm', __dir__)
    output = AgentVM.run(cli, '--name', vm.name, 'status', capture:true)
    assert_includes output, 'SAVED_COPY_RUNTIME'
    %w[update apply].each do |command|
      error = assert_raises(AgentVM::Error) { AgentVM.run(cli, '--name', vm.name, command, capture:true) }
      assert_includes error.message, 'Retained throwaways keep their saved software'
      refute_includes error.message, 'SAVED_COPY_RUNTIME'
    end
  end

  def test_disabled_sharing_never_starts_a_service_or_looks_up_host_exports
    vm = AgentVM::VM.new(@source.config.merge('sharing'=>'none', 'share'=>'/missing-host-folder'))
    shared = AgentVM::Shared.new(vm)
    AgentVM.stub(:run, lambda { |*| flunk 'Disabled sharing made an external call' }) do
      shared.prepare
      shared.start
      shared.stop
    end
  end

  def test_running_or_suspended_source_cannot_be_copied
    AgentVM::VM.stub(:load, @source) do
      @source.stub(:running?, true) do
        assert_raises(AgentVM::Error) { @runner.create }
      end
      File.write(File.join(@source.tart_directory, 'state.vzvmsave'), 'suspended')
      assert_raises(AgentVM::Error) { @runner.create }
    end
    assert_empty AgentVM::Throwaway.entries
  end

  def test_strict_clone_failure_never_falls_back_to_a_full_copy
    function = Object.new
    def function.call(*); -1; end
    destination = File.join(@tmp, 'copy.img')
    Fiddle::Function.stub(:new, lambda { |*| function }) do
      AgentVM.stub(:run, lambda { |*| flunk 'Attempted an external full copy' }) do
        error = assert_raises(AgentVM::Error) do
          AgentVM::DiskFiles.copy(File.join(@source.tart_directory, 'disk.img'), destination, clone_only:true)
        end
        assert_match(/no full disk copy/, error.message)
      end
    end
    refute File.exist?(destination)
  end

  def test_delete_requires_a_known_stopped_copy_and_preserves_source
    vm = create
    id = vm.config['throwaway']['id']
    assert_raises(AgentVM::Error) { @runner.delete('source-box') }
    @runner.stub(:find, vm) do
      vm.stub(:running?, true) { assert_raises(AgentVM::Error) { @runner.delete(id) } }
      AgentVM.stub(:run, '') do
        @runner.stub(:system, true) { capture_io { @runner.delete(id) } }
      end
    end
    refute File.exist?(vm.state)
    refute File.exist?(vm.tart_directory)
    assert_equal 'disk.img-original', File.read(File.join(@source.tart_directory, 'disk.img'))
    assert File.file?(@source.file('admin-password'))
    assert File.directory?(@source.config['share'])
  end

  def test_script_failure_preserves_copy_and_returns_exit_status
    vm = create
    script = File.join(@tmp, 'task.sh')
    File.write(script, "#!/bin/sh\nexit 7\n")
    running = false
    vm.define_singleton_method(:start) { running = true }
    vm.define_singleton_method(:running?) { running }
    vm.define_singleton_method(:stop) { running = false }
    vm.define_singleton_method(:ssh) { |*args, **_options| args.first == '/usr/bin/mktemp' ? "/tmp/throwaway-run.fixture\n" : '' }
    @runner.define_singleton_method(:system) { |*| Kernel.system('/bin/sh', '-c', 'exit 7') }
    status = nil
    capture_io { status = @runner.run_script(vm, script, []) }
    assert_equal 7, status
    refute running
    assert File.file?(File.join(vm.tart_directory, 'disk.img'))
    assert File.file?(vm.file('admin-password'))
    assert_equal vm.name, @runner.find(vm.config['throwaway']['id']).name
  end
end
