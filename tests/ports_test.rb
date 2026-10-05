require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/ports'

class PortsTest < Minitest::Test
  def test_background_forward_does_not_keep_captured_command_output_open
    Dir.mktmpdir('forward-descriptors-') do |directory|
      helper = File.join(directory, 'fake-ssh.rb')
      pid_file = File.join(directory, 'background.pid')
      File.write(helper, <<~RUBY)
        child = fork { sleep 30 }
        File.write(#{pid_file.dump}, child.to_s)
        exit! 0
      RUBY
      script = <<~RUBY
        require #{File.expand_path('../lib/ports', __dir__).dump}
        vm = Object.new
        vm.define_singleton_method(:name) { 'test-box' }
        vm.define_singleton_method(:ssh_args) { ['/usr/bin/ruby', #{helper.dump}] }
        vm.define_singleton_method(:file) { |name| File.join(#{directory.dump}, name) }
        vm.define_singleton_method(:control_socket) { |name| file(name) }
        AgentVM::Ports.new(vm).open('direction'=>'host', 'from'=>8000, 'to'=>9000)
        puts 'forward returned'
      RUBY
      output = AgentVM.run('/usr/bin/ruby', '-e', script, capture:true, timeout:5)
      assert_equal "forward returned\n", output
      assert Process.kill(0, Integer(File.read(pid_file))), 'Background forward should still be running'
    ensure
      Process.kill('TERM', Integer(File.read(pid_file))) if pid_file && File.file?(pid_file)
    end
  end

  def test_repeated_forward_keeps_existing_connection_and_conflicting_actions_do_nothing
    Dir.mktmpdir('forward-state-') do |directory|
      vm = Object.new
      vm.define_singleton_method(:file) { |name| File.join(directory,name) }
      ports = AgentVM::Ports.new(vm)
      calls = []
      ports.define_singleton_method(:open) { |entry| calls << [:open,entry] }
      ports.define_singleton_method(:close) { |entry| calls << [:close,entry] }
      ports.define_singleton_method(:alive?) { |_| true }
      ports.define_singleton_method(:list) { }
      ports.add('host',8000,9000)
      path=vm.file('ports.json')
      before=File.stat(path).ino
      calls.clear
      ports.add('host',8000,9000)
      assert_empty calls
      assert_equal before,File.stat(path).ino
      File.open(vm.file('ports.lock'),'w') do |lock|
        lock.flock(File::LOCK_EX)
        assert_raises(AgentVM::Error) { ports.add('guest',8001,9001) }
        assert_raises(AgentVM::Error) { ports.remove('host','8000') }
      end
      assert_empty calls
      original=File.read(path)
      AgentVM.stub(:json_write, ->(*) { raise AgentVM::Error,'Disk full' }) do
        assert_raises(AgentVM::Error) { ports.add('guest',8001,9001) }
      end
      assert_equal [:open,:close],calls.map(&:first)
      assert_equal original,File.read(path)
    end
  end
end
