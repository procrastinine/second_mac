require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/network-supervisor'
require_relative '../lib/network'

class NetworkSupervisorTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('sm-net-', '/private/tmp')
    @socket = File.join(@directory, 'control.sock')
    @wire, child = Socket.pair(:UNIX, :DGRAM, 0)
    @first, @second = %w[first second].map do |name|
      path = File.join(@directory, name)
      File.write(path, <<~RUBY)
        #!/usr/bin/ruby
        require 'socket'
        socket = Socket.for_fd(0)
        Signal.trap('INT') { exit }
        loop do
          value = socket.recv(8192)
          socket.send('#{name}:' + Process.pid.to_s + ':' + value, 0)
        end
      RUBY
      File.chmod(0700, path)
      path
    end
    log = File.open(File.join(@directory, 'log'), 'w')
    @pid = Process.spawn({'SECOND_MAC_NETWORK_SOCKET'=>@socket, 'SECOND_MAC_NETWORK_BACKEND'=>'vpn',
                          'SECOND_MAC_NETWORK_BINARY'=>@first},
                         File.expand_path('../lib/network-bin/softnet', __dir__),
                         '--vm-fd', '0', '--vm-mac-address', '02:00:00:00:00:01', '--block', '@host',
                         in:child, out:log, err:log)
    child.close
    log.close
    Timeout.timeout(5) { sleep 0.02 until File.socket?(@socket) }
    @status = request('op'=>'network-status')
  end
  def teardown
    if @pid
      Process.kill('TERM', @pid) rescue nil
      Timeout.timeout(8) { Process.waitpid(@pid) } rescue nil
    end
    @wire.close
    FileUtils.remove_entry(@directory)
  end
  def request(value)
    socket = UNIXSocket.new(@socket)
    Timeout.timeout(8) do
      socket.puts(JSON.generate(value))
      JSON.parse(socket.gets)
    end
  ensure
    socket.close if socket
  end
  def packet(text)
    @wire.send(text, 0)
    Timeout.timeout(5) { @wire.recv(8192) }
  end
  def test_switch_hands_same_socket_directly_to_child_and_cleans_up
    vm = Struct.new(:path) { def control_socket(_); path; end }.new(@socket)
    assert_equal @status, AgentVM::Network.new(vm).request('op'=>'network-status')
    assert_equal Process.pid, @status['pid']
    assert_equal '@host', @status['blocks']
    assert_equal @pid, @status['supervisor_pid']
    first_child = @status.fetch('helper_pid')
    assert_equal "first:#{first_child}:before", packet('before')
    changed = request('op'=>'network-set', 'backend'=>'vpn', 'binary'=>@second, 'blocks'=>'@host,10.0.0.0/8')
    assert_equal @pid, changed['supervisor_pid']
    assert_equal '@host,10.0.0.0/8', changed['blocks']
    second_child = changed.fetch('helper_pid')
    refute_equal first_child, second_child
    assert_raises(Errno::ESRCH) { Process.kill(0, first_child) }
    assert_equal "second:#{second_child}:after", packet('after')
    assert_equal 0600, File.stat(@socket).mode & 0777
    Process.kill('INT', @pid)
    Timeout.timeout(8) { Process.waitpid(@pid) }
    @pid = nil
    refute File.exist?(@socket)
    assert_raises(Errno::ESRCH) { Process.kill(0, second_child) }
  end
  def test_invalid_request_cannot_replace_active_helper
    invalid = request('op'=>'network-set', 'backend'=>'native', 'binary'=>@second, 'blocks'=>'@host')
    assert invalid['error']
    assert_equal @status['helper_pid'], request('op'=>'network-status')['helper_pid']
    assert_equal "first:#{@status['helper_pid']}:still-active", packet('still-active')
  end
  def test_child_failure_keeps_control_alive_without_falling_back_and_can_recover
    Process.kill('KILL', @status['helper_pid'])
    status = nil
    Timeout.timeout(5) do
      loop do
        status = request('op'=>'network-status')
        break unless status['healthy']
        sleep 0.02
      end
    end
    assert_equal 'vpn', status['backend']
    assert_equal @pid, status['supervisor_pid']
    changed = request('op'=>'network-set', 'backend'=>'vpn', 'binary'=>@second, 'blocks'=>'@host')
    assert changed['healthy']
    assert_equal "second:#{changed['helper_pid']}:recovered", packet('recovered')
  end
end
