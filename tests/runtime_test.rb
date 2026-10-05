require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/runtime'
require_relative '../lib/suspend'

class RuntimeTest < Minitest::Test
  def setup
    @environment=ENV.to_h
    @dir=Dir.mktmpdir('runtime-policy-')
    ENV['AGENT_VM_HOME']=File.join(@dir,'state')
    ENV['TART_HOME']=File.join(@dir,'tart')
    @vm=AgentVM::VM.new(AgentVM::DEFAULTS.merge('name'=>'test-box','phase'=>'ready','ui_enabled'=>true,'tart'=>'/test/tart','tart_version'=>'2.40.1'))
    FileUtils.mkdir_p(@vm.tart_directory)
    FileUtils.mkdir_p(@vm.state)
    @vm.define_singleton_method(:running_pid) { 123 }
    @vm.define_singleton_method(:stop) { raise 'unexpected stop' }
    @vm.define_singleton_method(:start) { |**| raise 'unexpected start' }
  end
  def teardown
    ENV.replace(@environment)
    FileUtils.remove_entry(@dir)
  end
  def test_selection_preserves_the_actual_running_runtime_until_next_cold_start
    AgentVM.json_write(@vm.file('access-launch.json'),{'pid'=>123,'runtime'=>'custom','ui_enabled'=>true,'shares'=>[]})
    runtime=AgentVM::Runtime.new(@vm)
    capture_io { runtime.choose('standard',build:false) }
    report=runtime.report
    assert_equal 'standard',report['selection']
    assert_equal 'standard',report['next_start']
    assert_equal 'custom',report['active']
    assert @vm.config['ui_enabled'], 'Remember the desired custom features when selecting standard'
    assert_raises(AgentVM::Error) { runtime.choose('unknown',build:false) }
  end
  def test_old_process_does_not_claim_new_controller_features
    AgentVM.json_write(@vm.file('ui-process.json'),{'pid'=>123,'binary'=>'/old/build'})
    current=AgentVM::Runtime.new(@vm).current
    assert_equal 'custom',current['runtime']
    assert_empty current['features']
    refute AgentVM::Suspend.new(@vm).supported?
  end
  def test_memory_resume_refuses_modified_hardware_without_removing_the_state
    @vm.define_singleton_method(:running_pid) { 0 }
    hardware=File.join(@vm.tart_directory,'config.json')
    binary=File.join(@dir,'tart-bin')
    AgentVM.write(binary,'test executable',0700)
    AgentVM.write(hardware,'original configuration')
    suspension=AgentVM::Suspend.new(@vm)
    AgentVM.write(suspension.path,'saved memory',0600)
    AgentVM.json_write(suspension.marker,{'status'=>'saved','configuration'=>@vm.config,'binary'=>binary,
      'binary_sha256'=>Digest::SHA256.file(binary).hexdigest,'hardware_sha256'=>Digest::SHA256.file(hardware).hexdigest})
    assert_equal @vm.config, suspension.resume_configuration
    AgentVM.write(hardware,'changed configuration')
    error=assert_raises(AgentVM::Error) { suspension.resume_configuration }
    assert_includes error.message,'hardware changed'
    assert_equal 'saved memory',File.read(suspension.path)
  end
  def test_unmanaged_saved_memory_never_falls_back_to_a_cold_start
    @vm.define_singleton_method(:running_pid) { 0 }
    AgentVM.write(File.join(@vm.tart_directory,'state.vzvmsave'),'saved memory',0600)
    error=assert_raises(AgentVM::Error) { @vm.launch_unlocked }
    assert_includes error.message,'refusing to guess'
    assert @vm.suspended?
  end

  def test_partial_upstream_memory_file_cannot_be_resumed_or_force_stopped
    @vm.define_singleton_method(:running_pid) { 0 }
    suspension=AgentVM::Suspend.new(@vm)
    AgentVM.write(suspension.path,'partial memory',0600)
    AgentVM.json_write(suspension.marker,{'status'=>'saving','configuration'=>{'runtime_mode'=>'standard'},'stdout_offset'=>0})
    AgentVM.write(@vm.file('stdout.log'),'saving failed: disk full')
    assert_raises(AgentVM::Error) { suspension.resume_configuration }
    assert_raises(AgentVM::Error) { suspension.save }
    assert_equal 'partial memory',File.read(suspension.path)
    assert_equal 'saving',suspension.record['status']
  end
  def test_explicit_checkpoint_discard_keeps_disk_and_refuses_running_guest
    suspension=AgentVM::Suspend.new(@vm)
    disk=File.join(@vm.tart_directory,'disk.img')
    AgentVM.write(disk,'valuable disk data')
    AgentVM.write(suspension.path,'incomplete memory')
    AgentVM.json_write(suspension.marker,{'status'=>'saving'})
    assert_raises(AgentVM::Error) { suspension.command(['discard']) }
    assert_raises(AgentVM::Error) { suspension.command(['discard','--yes']) }
    assert File.file?(suspension.path)
    @vm.define_singleton_method(:running_pid) { 0 }
    capture_io { suspension.command(['discard','--yes']) }
    refute File.exist?(suspension.path)
    refute File.exist?(suspension.marker)
    assert_equal 'valuable disk data',File.read(disk)
  end
  def test_completed_atomic_save_recovers_after_client_interruption
    @vm.define_singleton_method(:running_pid) { 0 }
    suspension=AgentVM::Suspend.new(@vm)
    hardware=File.join(@vm.tart_directory,'config.json')
    binary=File.join(@dir,'tart-bin')
    AgentVM.write(binary,'runtime',0700)
    AgentVM.write(hardware,'hardware')
    AgentVM.write(suspension.path,'complete atomic save')
    config=@vm.config.merge('runtime_mode'=>'custom')
    AgentVM.json_write(suspension.marker,{'status'=>'saving','configuration'=>config,'binary'=>binary,
      'binary_sha256'=>Digest::SHA256.file(binary).hexdigest,'hardware_sha256'=>Digest::SHA256.file(hardware).hexdigest})
    assert_equal config,suspension.resume_configuration
    assert_equal 'saved',suspension.record['status']
  end
end
