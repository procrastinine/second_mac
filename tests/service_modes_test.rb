require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/credentials'
require_relative '../lib/guest-control'

class ServiceModesTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('service-modes-')
    @old = ENV['AGENT_VM_HOME']; ENV['AGENT_VM_HOME'] = @directory
    @vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('share'=>File.join(@directory,'share')))
    @vm.save
    @owner = 123
    owner = -> { @owner }
    @vm.define_singleton_method(:running_pid) { owner.call }
    @vm.define_singleton_method(:ui_available?) { true }
    AgentVM::HostCredentials.store('fixture-key')
  end
  def teardown
    ENV['AGENT_VM_HOME'] = @old
    FileUtils.remove_entry(@directory)
  end
  def each_service
    [AgentVM::Credentials.new(@vm), AgentVM::GuestControl.new(@vm)].each do |service|
      service.stub(:start, nil) do
        service.stub(:system, true) do
          # Guest client mutation is covered separately and in live lifecycle
          # verification; these tests exercise the actual persisted modes.
          if service.is_a?(AgentVM::Credentials)
            service.stub(:client, nil) { yield service, ->(*args) { capture_io { service.command(['relay', *args]) } } }
          else
            yield service, ->(*args) { capture_io { service.command(args) } }
          end
        end
      end
    end
  end
  def test_current_run_changes_and_future_starts_are_independent_for_both_services
    each_service do |service, command|
      command.call('on')
      assert service.enabled?
      assert service.autostart?
      command.call('off','--once')
      refute service.enabled?
      assert service.autostart?
      command.call('autostart','off')
      refute service.enabled?
      refute service.autostart?
      command.call('on','--once')
      assert service.enabled?
      refute service.autostart?
      command.call('autostart','on')
      assert service.enabled?
      assert service.autostart?
      command.call('autostart','off')
      assert service.enabled?, 'disabling future starts must keep this run'
      refute service.autostart?
      @owner += 1
      refute service.enabled?, 'a run-only grant must not carry to another Tart process'
      command.call('on')
      command.call('off','--once')
      service.stop
      @owner += 1
      assert service.enabled?, 'a run-only stop must not disable the next automatic start'
      command.call('off')
      refute service.enabled?
      refute service.autostart?
    end
  end
  def test_future_enable_never_starts_current_run_and_stopped_once_is_rejected
    each_service do |service, command|
      command.call('off')
      command.call('autostart','on')
      refute service.enabled?
      assert service.autostart?
      @owner += 1
      assert service.enabled?
      @owner = 0
      before = File.read(@vm.file('config.json'))
      %w[on off].each do |mode|
        assert_raises(AgentVM::Error) { command.call(mode,'--once') }
        assert_equal before, File.read(@vm.file('config.json'))
      end
      @owner = 123
    end
  end
  def test_missing_or_empty_host_key_cannot_start_relay
    service = AgentVM::Credentials.new(@vm)
    File.unlink(AgentVM::HostCredentials.path)
    service.set_autostart(true)
    @owner += 1
    service.stub(:system, ->(*) { flunk 'Missing key started a service or tunnel' }) do
      capture_io { service.start }
      assert_nil service.serve(@owner.to_s)
      refute service.active?
      assert_raises(AgentVM::Error) { service.set('on') }
      AgentVM::HostCredentials.prepare
      capture_io { service.start }
      refute File.exist?(service.state_path)
      refute File.exist?(service.grant_path)
    end
  end
  def test_optional_installer_prompt_can_skip_without_creating_a_key
    File.unlink(AgentVM::HostCredentials.path)
    IO.stub(:console, nil) do
      capture_io { refute AgentVM::HostCredentials.prompt(optional:true) }
      refute File.exist?(AgentVM::HostCredentials.path)
    end
    console = Object.new
    console.define_singleton_method(:getpass) { |_| '' }
    IO.stub(:console, console) do
      capture_io { refute AgentVM::HostCredentials.prompt(optional:true) }
      refute File.exist?(AgentVM::HostCredentials.path)
    end
  end
  def test_key_entry_preserves_saved_key_on_cancel_or_invalid_input
    console = Object.new
    console.define_singleton_method(:getpass) { |_| '' }
    IO.stub(:console, console) { assert_raises(AgentVM::Error) { AgentVM::HostCredentials.prompt(replace:true) } }
    assert_equal 'fixture-key', AgentVM::HostCredentials.read
    assert_raises(AgentVM::Error) { AgentVM::HostCredentials.store("invalid key\n") }
    assert_equal 'fixture-key', AgentVM::HostCredentials.read
    console.define_singleton_method(:getpass) { |_| 'replacement-key' }
    IO.stub(:console, console) { assert AgentVM::HostCredentials.prompt(replace:true) }
    assert_equal 'replacement-key', AgentVM::HostCredentials.read
    assert_equal 0600, File.stat(AgentVM::HostCredentials.path).mode & 0777
  end
  def test_pi_needs_consent_to_reuse_an_existing_host_key
    console = Object.new
    console.define_singleton_method(:print) { |_| }
    console.define_singleton_method(:getpass) { |_| flunk 'Existing key must not be requested again' }
    ['', 'n', 'no', nil].each do |answer|
      console.define_singleton_method(:gets) { answer }
      IO.stub(:console, console) { capture_io { refute AgentVM::HostCredentials.offer_pi } }
    end
    console.define_singleton_method(:gets) { "yes\n" }
    IO.stub(:console, console) { capture_io { assert AgentVM::HostCredentials.offer_pi } }
    IO.stub(:console, nil) { capture_io { refute AgentVM::HostCredentials.offer_pi } }
    assert_equal 'fixture-key', AgentVM::HostCredentials.read
  end
end
