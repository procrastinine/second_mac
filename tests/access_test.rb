require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/access'
require_relative '../lib/throwaway'

class AccessTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('second-mac-access-')
    @old = ENV['AGENT_VM_HOME']
    ENV['AGENT_VM_HOME'] = @tmp
    @vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('share'=>File.join(@tmp, 'share'), 'tart'=>'/fake/tart'))
    @vm.save
    @vm.define_singleton_method(:running_pid) { 0 }
    @vm.define_singleton_method(:start) { raise 'Inspection must never boot' }
    @vm.define_singleton_method(:save) { raise 'Inspection must not change configuration' }
    @vm.define_singleton_method(:rpc) { |*, **_| raise 'Must not query a stopped guest' }
    @access = AgentVM::Access.new(@vm)
  end
  def teardown
    ENV['AGENT_VM_HOME'] = @old
    FileUtils.remove_entry(@tmp)
  end
  def test_stopped_view_has_configured_folders_without_active_grants_or_side_effects
    before = Dir.glob(@tmp+'/**/*', File::FNM_DOTMATCH).sort
    report = nil
    AgentVM.stub(:run, ->(*, **_) { flunk 'Stopped inspection needs no external commands' }) { report = @access.report }
    assert_equal 'stopped', report['state']
    assert_equal [false, true, false], report['shares']['configured'].map { |share| share['read_only'] }
    assert_empty report['shares']['attached']
    assert_empty report['shares']['mounted']
    refute report['control']['guest_delegation']['active']
    assert_equal before, Dir.glob(@tmp+'/**/*', File::FNM_DOTMATCH).sort
  end
  def with_live_probes
    @vm.define_singleton_method(:running_pid) { 123 }
    @vm.define_singleton_method(:rpc) { |*args, **_| args == ['/sbin/mount'] ? "tag on /Volumes/shared_files (virtiofs, local)\ntag on /Volumes/readonly_files (virtiofs, local, read-only)\n" : raise('Unexpected guest command') }
    network = Object.new
    network.define_singleton_method(:observed_status) { {'pid'=>123, 'backend'=>'vpn', 'healthy'=>true} }
    control = Struct.new(:active?, :enabled?).new(false, false)
    camera = Struct.new(:active?).new(false)
    status = Struct.new(:success?).new(false)
    AgentVM::Network.stub(:new, network) do
      AgentVM::GuestControl.stub(:new, control) do
        AgentVM::Camera.stub(:new, camera) do
          Open3.stub(:capture2e, ['', status]) { yield }
        end
      end
    end
  end
  def test_active_view_separates_pending_settings_and_never_dumps_credentials
    @vm.config['audio_output'] = true
    @vm.config['ui_enabled'] = false
    @vm.config['secret'] = 'never-display-this'
    AgentVM.json_write(@vm.file('access-launch.json'), {'pid'=>123,
      'shares'=>AgentVM.share_entries(@vm.config).take(2), 'audio_output'=>false, 'microphone'=>false, 'clipboard'=>false, 'usb'=>false,
      'password'=>'never-display-this'})
    AgentVM.json_write(@vm.file('ports.json'), [{'direction'=>'host', 'from'=>8080, 'to'=>8081}, {'direction'=>'guest', 'from'=>3000, 'to'=>3001}])
    ports = AgentVM::Ports.new(@vm)
    ports.define_singleton_method(:alive?) { |_| true }
    with_live_probes do
      AgentVM::Ports.stub(:new, ports) do
        data = @access.report
        assert_equal 3, data['shares']['configured'].size
        assert_equal 2, data['shares']['attached'].size
        assert_equal [false, true], data['shares']['mounted'].map { |m| m['read_only'] }
        assert data['devices']['audio_output']['configured']
        refute data['devices']['audio_output']['attached']
        assert_equal 'vpn', data['network']['active_backend']
        assert_equal ['guest 127.0.0.1:8081', 'host 127.0.0.1:3001'], data['ports'].map { |p| p['listener'] }
        assert_equal ['host 127.0.0.1:8080', 'guest 127.0.0.1:3000'], data['ports'].map { |p| p['service'] }
        refute_includes JSON.generate(data), 'never-display-this'
        assert_includes @access.render(data), 'configured on; attached off'
      end
    end
  end
  def test_unavailable_evidence_is_unknown_and_old_copy_inspection_does_not_migrate_it
    with_live_probes do
      @vm.define_singleton_method(:rpc) { |*, **_| raise AgentVM::Error, 'private transport failure detail' }
      AgentVM.json_write(@vm.file('access-launch.json'), {'pid'=>999, 'shares'=>[]})
      data = @access.report
      assert_nil data['shares']['attached']
      assert_nil data['shares']['mounted']
      assert_nil data['devices']['microphone']['attached']
      assert_includes data['unavailable'], 'guest mount status'
      refute_includes JSON.generate(data), 'private transport failure detail'
    end
    @vm.define_singleton_method(:running_pid) { 0 }
    @vm.config['sharing'] = 'none'
    @vm.config['throwaway'] = {'id'=>'0123abcd'}
    manager = AgentVM::Throwaway.new
    manager.define_singleton_method(:find) { |_| @copy }
    manager.instance_variable_set(:@copy, @vm)
    before = File.read(@vm.file('config.json'))
    output, = capture_io { assert_equal 0, manager.command(%w[access 0123abcd --json]) }
    assert_empty JSON.parse(output)['shares']['configured']
    assert_equal before, File.read(@vm.file('config.json'))
    refute File.exist?(@vm.file('runtime'))
  end
end
