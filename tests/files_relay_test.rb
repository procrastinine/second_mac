require 'minitest/autorun'
require 'tmpdir'
require 'timeout'
require_relative '../lib/files-relay'

class FilesRelayTest < Minitest::Test
  def setup
    @tmp = File.realpath(Dir.mktmpdir('second-mac-relay-'))
    @old_state = ENV['AGENT_VM_HOME']
    ENV['AGENT_VM_HOME'] = File.join(@tmp, 'state')
    tool = File.join(@tmp, 'fake-tart')
    AgentVM.write(tool, <<~'RUBY', 0755)
      #!/usr/bin/ruby
      # A byte-stream guest transport; accepting only the relay's fixed target
      # catches an accidental SSH invocation or an unintended network grant.
      exit 0 if ARGV[2] == '/usr/bin/pkill'
      abort 'Unexpected transport' unless ARGV[0,2] == ['exec','-i'] &&
        ARGV[3] == '/opt/homebrew/bin/socat' && ARGV[-2,2] == ['STDIO','TCP4:127.0.0.1:445']
      $stdin.binmode
      $stdout.binmode
      $stdout.sync = true
      loop { $stdout.write($stdin.readpartial(65536)) }
    RUBY
    @vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('share'=>File.join(@tmp, 'share'), 'tart'=>tool))
    @vm.save
    owner_path = @vm.file('test-owner')
    File.write(owner_path, '42')
    @vm.define_singleton_method(:running_pid) { File.read(owner_path).to_i }
    @generation = SecureRandom.hex(16)
  end
  def teardown
    if @pid
      Process.kill('TERM', @pid) rescue nil
      Timeout.timeout(15) { Process.waitpid(@pid) } rescue nil
    end
    ENV['AGENT_VM_HOME'] = @old_state
    FileUtils.remove_entry(@tmp)
  end
  def wait_until
    Timeout.timeout(15) { sleep 0.02 until yield }
  end
  def test_loopback_stream_is_exact_and_owner_exit_closes_clients_and_service
    @pid = fork do
      $stdout.reopen(File::NULL, 'w')
      $stderr.reopen(File::NULL, 'w')
      AgentVM::FilesRelay.new(@vm, 42, @generation).run
      exit! 0
    end
    path = @vm.file('files-relay.json')
    wait_until { File.file?(path) }
    data = JSON.parse(File.read(path))
    assert_equal @generation, data['generation']
    assert_equal @pid, data['pid']
    clients = 2.times.map { TCPSocket.new('127.0.0.1', data['port']) }
    clients.each do |client|
      assert_equal '127.0.0.1', client.peeraddr[3]
      payload = SecureRandom.random_bytes(64 * 1024)
      client.write(payload)
      assert_equal payload, Timeout.timeout(5) { client.read(payload.bytesize) }
    end
    File.write(@vm.file('test-owner'), '0')
    Timeout.timeout(10) { Process.waitpid(@pid) }
    @pid = nil
    refute File.exist?(path)
    assert_raises(Errno::ECONNREFUSED) { TCPSocket.new('127.0.0.1', data['port']) }
    clients.each { |client| assert_nil Timeout.timeout(3) { client.read(1) } }
  ensure
    clients.each(&:close) if clients
  end
  def test_invalid_owner_or_generation_cannot_start_a_relay
    assert_raises(AgentVM::Error) { AgentVM::FilesRelay.new(@vm, 0, @generation) }
    assert_raises(AgentVM::Error) { AgentVM::FilesRelay.new(@vm, 42, '.*') }
    relay = AgentVM::FilesRelay.new(@vm, 99, @generation)
    assert_raises(AgentVM::Error) { relay.run }
    refute File.exist?(@vm.file('files-relay.json'))
  end
end
