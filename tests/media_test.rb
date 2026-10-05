require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/camera'
require_relative '../lib/microphone'

class MediaTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('second-mac-media-')
    @old = ENV['AGENT_VM_HOME']
    ENV['AGENT_VM_HOME'] = @directory
    @vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('name'=>'media-box', 'user'=>'developer',
      'share'=>File.join(@directory, 'share'), 'tart'=>'/fake/tart'))
    @events = []
    events = @events
    @vm.define_singleton_method(:save) { events << :save }
    @vm.define_singleton_method(:stop) { events << :stop }
    @vm.define_singleton_method(:start) { events << :start }
  end
  def teardown
    ENV['AGENT_VM_HOME'] = @old
    FileUtils.remove_entry(@directory)
  end
  def test_media_defaults_are_off_and_invalid_values_are_rejected
    refute @vm.config['microphone']
    refute @vm.config['camera_obs']
    assert_includes @vm.run_args, '--no-audio'
    %w[microphone camera_obs].each do |key|
      assert_raises(AgentVM::Error) { AgentVM.validate(@vm.config.merge(key=>'yes')) }
    end
  end
  def test_microphone_choice_is_queued_without_ending_a_running_session
    @vm.stub(:running?, true) do
      capture_io { AgentVM::Microphone.new(@vm).command(['on']) }
      assert_equal [:save], @events
      assert @vm.config['microphone']
      @events.clear
      capture_io { AgentVM::Microphone.new(@vm).command(%w[on --restart]) }
      assert_equal [:stop, :start], @events
      refute_includes @vm.run_args, '--no-audio'
      @events.clear
      capture_io { AgentVM::Microphone.new(@vm).command(['on']) }
      assert_empty @events
    end
  end
  def test_a_stopped_vm_stays_stopped_when_opting_in
    @vm.stub(:running?, false) do
      capture_io { AgentVM::Microphone.new(@vm).command(['on']) }
      assert_equal [:save], @events
      assert @vm.config['microphone']
    end
  end
  def test_failed_camera_owner_validation_does_not_remove_other_generation
    FileUtils.mkdir_p(@vm.state)
    path = @vm.file('camera.json')
    data = JSON.generate('generation'=>'a'*32, 'owner'=>123, 'pid'=>456)
    File.write(path, data)
    camera = AgentVM::Camera.new(@vm)
    @vm.stub(:running_pid, 123) do
      assert_raises(AgentVM::Error) { camera.serve(123, nil) }
      assert_raises(AgentVM::Error) { camera.serve(123, 'a'*32) }
    end
    assert_equal data, File.read(path)
  end
end
