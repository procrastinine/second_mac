require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/audio'

class AudioTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('second-mac-audio-')
    @old = ENV['AGENT_VM_HOME']
    ENV['AGENT_VM_HOME'] = @tmp
    @vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('tart'=>'/official/tart', 'ui_tart'=>'/custom/tart'))
    @vm.define_singleton_method(:running?) { true }
    @vm.define_singleton_method(:running_pid) { 123 }
    @vm.save
    AgentVM.json_write(@vm.file('access-launch.json'), {'pid'=>123, 'audio_output'=>false})
    @audio = AgentVM::Audio.new(@vm)
    @events = []
    events = @events
    @vm.define_singleton_method(:start) { events << :start }
    @vm.define_singleton_method(:stop) { events << :stop }
  end
  def teardown
    ENV['AGENT_VM_HOME'] = @old
    FileUtils.remove_entry(@tmp)
  end
  def test_output_only_is_persisted_without_restarting_or_enabling_input_or_ui
    capture_io { @audio.command(['on']) }
    assert_empty @events
    assert @vm.config['audio_output']
    refute @vm.config['microphone']
    refute @vm.config['ui_enabled']
    assert_equal '/custom/tart', @vm.run_args.first
    assert_includes @vm.run_args, '--no-audio' # No upstream microphone input.
    assert AgentVM::VM.load(@vm.name).config['audio_output']
    assert_equal false, @audio.attached
    capture_io { @audio.command(%w[on --restart]) }
    assert_equal [:stop, :start], @events
  end
  def test_mute_and_unmute_only_change_guest_volume_and_preserve_sessions
    AgentVM.json_write(@vm.file('access-launch.json'), {'pid'=>123, 'audio_output'=>true})
    calls = []
    @vm.stub(:rpc, ->(*args, **_) { calls << args; '' }) do
      capture_io { @audio.command(['mute']); @audio.command(['unmute']) }
    end
    assert_equal [
      ['/usr/bin/osascript', '-e', 'set volume output muted true'],
      ['/usr/bin/osascript', '-e', 'set volume output muted false']
    ], calls
    assert_empty @events
    capture_io { @audio.command(['on']); @audio.command(%w[on --restart]) }
    assert_empty @events # Already attached: no needless restart.
  end
  def test_stopped_and_stale_receipts_do_not_claim_live_audio
    @vm.stub(:running?, false) do
      capture_io { @audio.command(%w[on --restart]) }
      assert_empty @events
      assert_equal false, @audio.attached
      assert_raises(AgentVM::Error) { @audio.command(['unmute']) }
    end
    AgentVM.json_write(@vm.file('access-launch.json'), {'pid'=>999, 'audio_output'=>true})
    assert_nil @audio.attached
  end
  def test_legacy_audio_choice_is_preserved_but_new_input_and_output_are_independent
    config = AgentVM.validate(AgentVM::DEFAULTS.merge('microphone'=>true))
    assert config['audio_output']
    config['audio_output'] = false
    assert AgentVM.validate(config)['microphone']
    assert_equal false, config['audio_output']
    assert_raises(AgentVM::Error) { AgentVM.validate(config.merge('audio_output'=>'yes')) }
  end
end
