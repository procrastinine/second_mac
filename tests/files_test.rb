require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/files'

class FilesTest < Minitest::Test
  def setup
    @previous = ENV['AGENT_VM_HOME']
    @tmp = File.realpath(Dir.mktmpdir('agent-vm-files-'))
    ENV['AGENT_VM_HOME'] = File.join(@tmp, 'state')
    @vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('share'=>File.join(@tmp, 'share')))
    @vm.save
    @vm.define_singleton_method(:running?) { true }
    @files = AgentVM::Files.new(@vm)
    @files.instance_variable_set(:@mount, File.join(@tmp, 'mount'))
    @files.define_singleton_method(:mounted?) { false }
    @closed = []
    closed = @closed
    @files.define_singleton_method(:close_transport) { closed << true }
  end
  def teardown
    ENV['AGENT_VM_HOME'] = @previous
    FileUtils.remove_entry(@tmp)
  end
  def test_nonempty_mountpoint_is_rejected_before_opening_a_tunnel
    AgentVM.write(File.join(@tmp, 'mount', 'keep.txt'), 'keep')
    AgentVM.stub(:run, ->(*) { flunk 'Must not start a tunnel for an occupied mountpoint' }) do
      assert_raises(AgentVM::Error) { @files.mount(open_finder:false) }
    end
    assert_equal 'keep', File.read(File.join(@tmp, 'mount', 'keep.txt'))
  end
  def test_partial_tunnel_failure_is_cleaned_up
    @files.define_singleton_method(:start_transport) { raise AgentVM::Error, 'simulated private relay failure' }
    capture_io do
      assert_raises(AgentVM::Error) { @files.mount(open_finder:false) }
    end
    assert_equal 2, @closed.length
  end
  def test_simultaneous_mount_operations_are_rejected
    File.open(@vm.file('files.lock'), File::RDWR | File::CREAT, 0600) do |lock|
      lock.flock(File::LOCK_EX)
      assert_raises(AgentVM::Error) { @files.mount(open_finder:false) }
    end
    assert_empty @closed
  end
  def test_busy_unmount_preserves_the_transport
    @files.define_singleton_method(:mounted?) { true }
    AgentVM.stub(:run, ->(*) { raise AgentVM::Error, 'busy filesystem' }) do
      assert_raises(AgentVM::Error) { @files.unmount }
    end
    assert_empty @closed
  end
  def test_symlink_mountpoint_is_rejected_without_changing_target
    target = File.join(@tmp, 'ordinary')
    Dir.mkdir(target)
    File.symlink(target, File.join(@tmp, 'mount'))
    assert_raises(AgentVM::Error) { @files.mount(open_finder:false) }
    assert_empty @closed
    assert Dir.empty?(target)
  end
end
