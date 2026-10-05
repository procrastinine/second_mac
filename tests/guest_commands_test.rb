require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/guest-commands'

class GuestCommandsTest < Minitest::Test
  Fake = Struct.new(:name, :dir) do
    def file(path)
      File.join(dir, path)
    end
  end

  def setup
    @tmp = Dir.mktmpdir('agent-vm-guest-commands-')
    @vm = Fake.new('box', @tmp)
    @local = File.join(@tmp, 'local.txt')
    File.write(@local, 'x')
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_one_ssh_argument_is_a_shell_line_and_several_are_an_argv
    assert_nil AgentVM::GuestCommands.remote_line([])
    assert_equal 'cd src && make | tail', AgentVM::GuestCommands.remote_line(['cd src && make | tail'])
    assert_equal "ls -la my\\ dir", AgentVM::GuestCommands.remote_line(['ls', '-la', 'my dir'])
  end

  def test_sudo_keeps_the_password_off_the_command_line
    line = AgentVM::GuestCommands.sudo_line(['installer', '-pkg', 'a b.pkg'])
    assert_equal "/usr/bin/sudo -k -S -p '' -- installer -pkg a\\ b.pkg", line
    shell = Shellwords.split(AgentVM::GuestCommands.sudo_line(['cat x | tee /etc/y']))
    assert_equal ['/bin/sh', '-c', 'cat x | tee /etc/y'], shell.last(3)
    assert_raises(AgentVM::Error) { AgentVM::GuestCommands.sudo_line([]) }
  end

  def test_cp_marks_guest_paths_with_a_colon_and_copies_one_way
    up = AgentVM::GuestCommands.copy_args(@vm, [@local, ':~/in'])
    assert_equal ['/usr/bin/scp', '-F', File.join(@tmp, 'ssh-config')], up.first(3)
    assert_equal [@local, 'box:~/in'], up.last(2)
    down = AgentVM::GuestCommands.copy_args(@vm, [':/tmp/a', ':', @tmp])
    assert_equal ['box:/tmp/a', 'box:.', @tmp], down.last(3)
    [[@local], [@local, @tmp], [':a', ':b'], [@local, ':a', ':b'], ['-r', @local, ':x']].each do |argv|
      assert_raises(AgentVM::Error, argv.inspect) { AgentVM::GuestCommands.copy_args(@vm, argv) }
    end
    error = assert_raises(AgentVM::Error) { AgentVM::GuestCommands.copy_args(@vm, ['nope.txt', ':x']) }
    assert_match(/No such host file: nope.txt/, error.message)
  end
end
