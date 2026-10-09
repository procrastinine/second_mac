require 'minitest/autorun'
require 'minitest/mock'
require 'stringio'
require_relative '../lib/clipboard'

class ClipboardTest < Minitest::Test
  def setup
    @vm = Struct.new(:name, :config, :running?, :ssh_args).new('test-box', {'user'=>'developer'}, true, ['/fixture/ssh'])
    @clipboard = AgentVM::Clipboard.new(@vm)
    @calls = []
  end

  def responses(*values)
    calls = @calls
    @clipboard.define_singleton_method(:capture) do |args, **options|
      calls << [args, options]
      raise 'Unexpected clipboard access' if values.empty?
      value = values.shift
      raise value if value.is_a?(Exception)
      value
    end
  end

  def test_invalid_arguments_and_stopped_guest_never_read_a_clipboard_or_start
    responses
    [[], %w[on], %w[to-guest extra], %w[to-host --force]].each do |args|
      assert_raises(AgentVM::Error) { @clipboard.command(args) }
    end
    @vm[:running?] = false
    assert_raises(AgentVM::Error) { @clipboard.command(['to-guest']) }
    assert_empty @calls
  end

  def test_desktop_login_is_checked_before_host_clipboard_read
    responses("loginwindow\n")
    assert_raises(AgentVM::Error) { @clipboard.command(['to-guest']) }
    assert_equal 1, @calls.size
    assert_equal %w[/usr/bin/stat -f %Su /dev/console], Shellwords.split(@calls.first[0].last)
  end

  def test_to_guest_is_one_snapshot_with_literal_unicode_and_trailing_newlines
    text = "fixture 中文 🔒 ' \" $(touch /tmp/unwanted) `id`\n\n"
    responses("developer\n", JSON.generate('text'=>text), '{"ok":true}')
    output, error = capture_io { @clipboard.command(['to-guest']) }
    assert_equal 3, @calls.size
    assert_equal '/usr/bin/osascript', @calls[1][0].first
    assert_equal 'read', @calls[1][0].last
    assert_equal ['/fixture/ssh', '-T', 'test-box'], @calls[2][0].take(3)
    assert_equal 'write', Shellwords.split(@calls[2][0].last).last
    assert_equal({'text'=>text}, JSON.parse(@calls[2][1].fetch(:input)))
    refute_includes @calls.map(&:first).inspect, text
    refute_includes output + error, 'fixture'
    assert_includes output, 'host to guest'
  end

  def test_to_host_reads_only_guest_and_never_pastes_or_reads_host
    responses("developer\n", '{"text":"{\\rtf1 literal}"}', '{"ok":true}')
    capture_io { @clipboard.command(['to-host']) }
    assert_equal ['/fixture/ssh', '-T', 'test-box'], @calls[1][0].take(3)
    assert_equal 'read', Shellwords.split(@calls[1][0].last).last
    assert_equal '/usr/bin/osascript', @calls[2][0].first
    assert_equal 'write', @calls[2][0].last
    assert_equal({'text'=>"{\rtf1 literal}"}, JSON.parse(@calls[2][1].fetch(:input)))
  end

  def test_unavailable_oversized_or_malformed_source_leaves_destination_untouched
    values = ['{"error":"no-text"}', '{"error":"too-large"}', 'secret invalid JSON', 'null',
              '{"text":3}', '{"text":"valid","extra":"secret"}',
              JSON.generate('text'=>'x' * (AgentVM::Clipboard::MAX_TEXT + 1))]
    values.each do |value|
      @calls.clear
      responses("developer\n", value)
      error = assert_raises(AgentVM::Error) { @clipboard.command(['to-host']) }
      refute_includes error.message, 'secret'
      assert_equal 2, @calls.size
    end
  end

  def test_read_failure_never_writes_destination
    responses("developer\n", AgentVM::Error.new('Clipboard transfer failed.'))
    assert_raises(AgentVM::Error) { @clipboard.command(['to-host']) }
    assert_equal 2, @calls.size
  end

  def test_guest_password_goes_directly_to_guest_without_reading_any_clipboard
    @vm.define_singleton_method(:password) { 'fixture-guest-password' }
    responses("developer\n", '{"ok":true}')
    out, err = capture_io { @clipboard.copy_password }
    assert_equal 2, @calls.size
    assert_equal ['/fixture/ssh', '-T', 'test-box'], @calls.last[0].take(3)
    assert_equal 'write', Shellwords.split(@calls.last[0].last).last
    assert_equal({'text'=>'fixture-guest-password'}, JSON.parse(@calls.last[1].fetch(:input)))
    refute_includes @calls.map(&:first).inspect, 'fixture-guest-password'
    refute_includes out + err, 'fixture-guest-password'
  end

  def test_process_streams_and_errors_never_reach_command_log_or_terminal
    log = StringIO.new
    Thread.current[:agent_vm_command_log] = log
    error = nil
    out, err = capture_io do
      error = assert_raises(AgentVM::Error) do
        @clipboard.send(:capture, ['/usr/bin/ruby', '-e', 'STDOUT.write(STDIN.read); STDERR.write("private-error"); exit 1'], input:'private-clipboard')
      end
    end
    assert_empty out + err + log.string
    refute_includes error.message, 'private'
  ensure
    Thread.current[:agent_vm_command_log] = nil
  end

  def test_native_process_output_is_bounded_and_timeouts_are_reaped
    error = assert_raises(AgentVM::Error) do
      @clipboard.send(:capture, ['/usr/bin/ruby', '-e', 'loop { STDOUT.write("x" * 16384) }'], limit:1024)
    end
    assert_includes error.message, 'limit'
    error = assert_raises(AgentVM::Error) do
      @clipboard.send(:capture, ['/usr/bin/ruby', '-e', 'sleep 10'], timeout:0.1)
    end
    assert_includes error.message, 'timed out'
  end
end
