require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/gui'

class GUITest < Minitest::Test
  class FakeVM
    attr_reader :calls, :config
    def initialize(state)
      @state, @pid, @running, @calls = state, 100, true, []
      @config = {'user'=>'developer'}
    end
    def file(path); File.join(@state, path); end
    def running?; @running; end
    def suspended?; false; end
    def needs_custom_tart?; @config['runtime_mode'] == 'custom'; end
    def running_pid; @running ? @pid : 0; end
    def ui_available?; @config['ui_enabled'] == true; end
    alias display_available? ui_available?
    def tart_directory; @state; end
    def stop; @calls << :stop; @running = false; end
    def start(graphics:false)
      @calls << [:start, graphics]
      @running, @pid = true, @pid + 1
      AgentVM.json_write(file('gui-process.json'), {'pid'=>@pid}) if graphics
    end
  end
  def setup
    @tmp = File.realpath(Dir.mktmpdir('agent-vm-gui-'))
    @vm = FakeVM.new(@tmp)
    @gui = AgentVM::GUI.new(@vm)
    @gui.define_singleton_method(:helper) { '/fake/gui-helper' }
  end
  def teardown
    FileUtils.remove_entry(@tmp)
  end
  def test_headless_attach_requires_explicit_restart
    assert_raises(AgentVM::Error) { @gui.command([]) }
    assert_empty @vm.calls
    AgentVM.stub(:run, true) do
      assert_output(/desktop opened/) { @gui.command(['--restart']) }
    end
    assert_equal [:stop, [:start, true]], @vm.calls
    assert @gui.active?
  end
  def test_show_and_hide_preserve_running_process
    AgentVM.json_write(@vm.file('gui-process.json'), {'pid'=>@vm.running_pid})
    before = @vm.running_pid
    calls = []
    AgentVM.stub(:run, lambda { |*args| calls << args }) do
      assert_output(/hidden/) { @gui.command(['--hide']) }
      assert_output(/desktop opened/) { @gui.command([]) }
    end
    assert_equal before, @vm.running_pid
    assert_empty @vm.calls
    assert_equal %w[hide show], calls.map(&:last)
  end
  def test_hide_does_not_wake_a_stopped_or_suspended_guest
    @vm.stop
    @vm.calls.clear
    @vm.define_singleton_method(:suspended?) { true }
    assert_output(/remains stopped or suspended/) { @gui.command(['--hide']) }
    assert_empty @vm.calls
  end
  def test_headless_hides_prepared_window_without_a_restart
    AgentVM.json_write(@vm.file('gui-process.json'), {'pid'=>@vm.running_pid})
    AgentVM.stub(:run, true) { assert_output(/without a visible window/) { @gui.command(['--headless']) } }
    assert_empty @vm.calls
    assert @gui.active?
    AgentVM.json_write(@vm.file('gui-process.json'), {'pid'=>999})
    refute @gui.active?
    assert_raises(AgentVM::Error) { @gui.command(['--hide']) }
  end
  def test_graphics_mode_keeps_all_isolation_flags
    vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('phase'=>'ready', 'tart'=>'/fake/tart', 'share'=>@tmp))
    headless = vm.run_args
    graphics = vm.run_args(graphics:true)
    assert_equal headless - ['--no-graphics'], graphics
    %w[--no-clipboard --no-audio --no-usb-accessories --net-softnet].each { |flag| assert_includes graphics, flag }
    assert graphics.any? { |flag| flag.start_with?('--net-softnet-block=@host,') }
    refute graphics.any? { |flag| flag.start_with?('--vnc') }
  end
  def test_custom_controller_shows_and_hides_without_any_vm_lifecycle_call
    require_relative '../lib/ui'
    @vm.config['ui_enabled'] = true
    calls = []
    desktop = Object.new
    desktop.define_singleton_method(:request) { |value, **| calls << value.fetch('op') }
    AgentVM::Desktop.stub(:new, desktop) do
      capture_io do
        @gui.command([])
        @gui.command(['--hide'])
        @gui.command([])
        @gui.command(['--headless'])
      end
    end
    assert_equal %w[show hide show hide], calls
    assert_empty @vm.calls
    assert_equal 100, @vm.running_pid
  end
  def test_custom_run_never_creates_a_second_stock_viewer_when_automation_is_off
    vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('phase'=>'ready', 'tart'=>'/fake/tart',
      'runtime_mode'=>'custom', 'ui_enabled'=>false, 'share'=>@tmp))
    assert_includes vm.run_args(graphics:true), '--no-graphics'
    vm.config['runtime_mode'] = 'standard'
    refute_includes vm.run_args(graphics:true), '--no-graphics'
  end
  def test_opening_a_stopped_custom_guest_uses_its_detachable_viewer
    require_relative '../lib/ui'
    @vm.stop
    @vm.calls.clear
    @vm.config.merge!('runtime_mode'=>'custom', 'ui_enabled'=>true)
    calls = []
    desktop = Object.new
    desktop.define_singleton_method(:request) { |value, **| calls << value.fetch('op') }
    AgentVM::Desktop.stub(:new, desktop) { capture_io { @gui.command([]) } }
    assert_equal [[:start, true]], @vm.calls
    assert_equal ['show'], calls
  end
end
