require 'minitest/autorun'
require 'minitest/mock'
require 'stringio'
require_relative '../lib/core'

class PasswordTest < Minitest::Test
  def setup
    @old_ssh, @old_tmux = ENV.values_at('SSH_CONNECTION', 'TMUX')
    ENV.delete('SSH_CONNECTION')
    ENV.delete('TMUX')
    @secret = 'test-only-password'
  end
  def teardown
    ENV['SSH_CONNECTION'], ENV['TMUX'] = @old_ssh, @old_tmux
  end
  def terminal_output
    original = $stdout
    terminal = StringIO.new
    terminal.define_singleton_method(:tty?) { true }
    $stdout = terminal
    yield
    terminal.string
  ensure
    $stdout = original
  end
  def test_default_host_copy_uses_stdin_without_printing_the_password
    calls = []
    AgentVM.stub(:run, lambda { |*args, **options| calls << [args, options] }) do
      assert_output("Guest password copied to the host clipboard.\n") do
        AgentVM.password_command(@secret, [])
      end
    end
    assert_equal [[['/usr/bin/pbcopy'], {input:@secret}]], calls
  end
  def test_password_display_never_leaks_into_logs
    assert_raises(AgentVM::Error) { AgentVM.password_command(@secret, ['--show']) }
  end
  def test_guest_ssh_copy_uses_terminal_clipboard_without_reading_it
    ENV['SSH_CONNECTION'] = 'test-ssh-connection'
    output = terminal_output { AgentVM.password_command(@secret, [], guest:true) }
    assert_includes output, "\e]52;c;#{Base64.strict_encode64(@secret)}\a"
    refute_includes output, @secret
    refute_includes output, ']52;c;?'
    assert_raises(AgentVM::Error) { AgentVM.password_command(@secret, [], guest:true) }
  end
  def test_guest_clipboard_can_be_selected_explicitly_from_ssh
    ENV['SSH_CONNECTION'] = 'test-ssh-connection'
    calls = []
    AgentVM.stub(:run, lambda { |*args, **options| calls << [args, options] }) do
      assert_output("Account password copied to this Mac's clipboard.\n") do
        AgentVM.password_command(@secret, ['--local'], guest:true)
      end
    end
    assert_equal [[['/usr/bin/pbcopy'], {input:@secret}]], calls
  end
  def test_tmux_copy_deletes_its_named_password_buffer
    ENV['SSH_CONNECTION'], ENV['TMUX'] = 'test-ssh-connection', 'test-tmux'
    calls = []
    AgentVM.stub(:run, lambda { |*args, **options| calls << [args, options] }) do
      output = terminal_output { AgentVM.password_command(@secret, [], guest:true) }
      refute_includes output, @secret
    end
    assert_equal ['load-buffer', '-b', 'mac-control-password', '-w', '-'], calls[0][0].drop(1)
    assert_equal @secret, calls[0][1][:input]
    assert_equal ['delete-buffer', '-b', 'mac-control-password'], calls[1][0].drop(1)
  end
end
