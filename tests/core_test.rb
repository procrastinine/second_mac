require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/core'

class CoreTest < Minitest::Test
  def setup
    @old_state = ENV['AGENT_VM_HOME']
    @tmp = File.realpath(Dir.mktmpdir('agent-vm-test-'))
    ENV['AGENT_VM_HOME'] = File.join(@tmp, "state space % percent ' quote")
    @config = AgentVM::DEFAULTS.merge('name'=>'test-box', 'user'=>'developer', 'share'=>File.join(@tmp, 'shared files'), 'tart'=>'/usr/bin/false')
    AgentVM.share_entries(@config).each { |entry| FileUtils.mkdir_p(entry['host']) }
  end
  def teardown
    ENV['AGENT_VM_HOME'] = @old_state
    FileUtils.remove_entry(@tmp)
  end
  def test_rejects_argument_and_path_injection
    ['../escape', 'name;false', "name\n", '-option'].each do |name|
      assert_raises(AgentVM::Error) { AgentVM.validate(@config.merge('name'=>name)) }
    end
    ['root', 'user name', 'user;false'].each do |user|
      assert_raises(AgentVM::Error) { AgentVM.validate(@config.merge('user'=>user)) }
    end
    assert_raises(AgentVM::Error) { AgentVM.validate(@config.merge('share'=>@tmp + "\0other")) }
    assert_raises(AgentVM::Error) { AgentVM.validate(@config.merge('guest_share'=>'tools')) }
  end
  def test_guest_configuration_never_includes_host_paths_or_private_state
    config = @config.merge('source_directory'=>@tmp, 'share_python'=>@tmp+'/python', 'host_label'=>'private-host-label')
    guest = AgentVM.guest_config(config)
    refute_includes JSON.generate(guest), @tmp
    refute guest.key?('source_directory')
    refute guest.key?('share_python')
    refute guest.key?('tart')
    assert_equal 'developer', guest['user']
    assert_equal '/Users/developer/shared_files', AgentVM.shares(config).first['guest']
    assert_equal %w[shared_files readonly_files linked_files], AgentVM.share_entries(guest).map { |entry| entry['name'] }
  end
  def test_ssh_config_supports_spaces_quotes_and_percent
    vm = AgentVM::VM.new(@config)
    vm.render_host
    output = AgentVM.run('/usr/bin/ssh', '-G', '-F', vm.file('ssh-config'), vm.name, capture:true)
    assert_includes output, 'user developer'
    assert_includes output, 'serveraliveinterval 0'
    assert_includes output, 'tcpkeepalive no'
    assert_includes output, 'forwardagent no'
    proxy = output.lines.find { |l| l.start_with?('proxycommand ') }.sub('proxycommand ', '').strip
    assert_equal ['/usr/bin/ruby',vm.file('runtime/lib/ssh-proxy.rb'),vm.file('config.json')], Shellwords.split(proxy.gsub('%%', '%'))
  end
  def test_state_files_are_private_and_plists_are_valid
    vm = AgentVM::VM.new(@config)
    vm.save
    vm.render_host
    assert_equal 0600, File.stat(vm.file('config.json')).mode & 0777
    assert_equal 0700, File.stat(vm.state).mode & 0777
    assert_includes AgentVM.run('/usr/bin/plutil', '-lint', vm.file('launch.plist'), capture:true), 'OK'
  end
  def test_concurrent_settings_keep_unrelated_changes_and_refuse_conflicts
    first = AgentVM::VM.new(@config)
    first.save
    second = AgentVM::VM.load(first.name)
    first.config['network_mode'] = 'off'
    first.save
    second.config['audio_output'] = true
    second.save
    assert_equal 'off', second.config['network_mode']
    assert AgentVM::VM.load(first.name).config['audio_output']
    first.config['network_mode'] = 'vpn'
    first.save
    second.config['network_mode'] = 'native'
    error = assert_raises(AgentVM::Error) { second.save }
    assert_includes error.message, 'network_mode'
    assert_equal 'vpn', AgentVM::VM.load(first.name).config['network_mode']
  end
  def test_noop_save_preserves_file_and_nested_mutations_are_persisted
    vm = AgentVM::VM.new(@config)
    vm.save
    path = vm.file('config.json')
    before = [File.stat(path).ino, File.stat(path).mtime]
    vm.save
    assert_equal before, [File.stat(path).ino, File.stat(path).mtime]
    vm = AgentVM::VM.load(vm.name)
    other = AgentVM::VM.load(vm.name)
    vm.config['agents'] << 'pi'
    vm.save
    other.config['timezone'] = 'Etc/UTC'
    other.save
    assert_equal ['pi'], other.config['agents']
    vm.config.delete('timezone')
    assert_raises(AgentVM::Error) { vm.save }
    assert_equal 'Etc/UTC', AgentVM::VM.load(vm.name).config['timezone']
  end
  def test_plan_has_no_install_side_effects
    source = File.expand_path('..', __dir__)
    output = AgentVM.run(File.join(source,'install.sh'), '--plan', '--name', 'other-box', '--user', 'builder', '--share', @config['share'], capture:true)
    assert_includes output, 'other-box'
    assert_includes output, 'builder'
    refute File.exist?(ENV['AGENT_VM_HOME'])
  end
  def test_runtime_check_detects_source_edits_additions_deletions_and_installed_drift
    source = File.join(@tmp, 'checkout')
    original = File.join(source, 'lib', 'example.rb')
    AgentVM.write(original, 'original')
    vm = AgentVM::VM.new(@config.merge('source_directory'=>source))
    installed = vm.file('runtime/lib/example.rb')
    AgentVM.write(installed, 'original')
    AgentVM.json_write(vm.file('source-manifest.json'), {'lib/example.rb'=>Digest::SHA256.file(original).hexdigest})
    assert_output(/current repository/) { vm.verify_runtime }
    File.write(original, 'edited')
    assert_raises(AgentVM::Error) { vm.verify_runtime }
    File.write(original, 'original')
    added = File.join(source, 'lib', 'new.rb')
    File.write(added, 'new')
    assert_raises(AgentVM::Error) { vm.verify_runtime }
    File.unlink(added)
    File.unlink(original)
    assert_raises(AgentVM::Error) { vm.verify_runtime }
    File.write(original, 'original')
    File.write(installed, 'drift')
    assert_raises(AgentVM::Error) { vm.verify_runtime }
    File.write(installed, 'original')
    File.unlink(vm.file('source-manifest.json'))
    assert_raises(AgentVM::Error) { vm.verify_runtime }
  end
  def test_command_timeout_reaps_child
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(AgentVM::Error) { AgentVM.run('/bin/sleep','30',timeout:0.1,capture:true) }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3
  end
  def test_blocked_networks_include_connected_subnets_even_with_public_addresses
    interfaces = "\tinet 203.0.113.42 netmask 0xffffff00 broadcast 203.0.113.255\n" +
                 "\tinet 192.168.50.2 netmask 0xffffff00\n" +
                 "\tinet 198.51.100.8 netmask 0x00000000\n"
    blocks = AgentVM.blocked_networks(interfaces)
    assert_includes blocks, '203.0.113.0/24'
    assert_includes blocks, '203.0.113.42/32'
    assert_includes blocks, '192.168.0.0/16'
    refute_includes blocks, '0.0.0.0/0'
    assert (AgentVM::PRIVATE_NETS - blocks).empty?
  end
  def test_private_vmnet_subnets_do_not_change_effective_restrictions
    lan = "en0: flags=8863\n\tinet 203.0.113.42 netmask 0xffffff00\n"
    expected = AgentVM.blocked_networks(lan)
    %w[10.47.29.97 172.24.158.169 192.168.46.201].each do |gateway|
      interfaces = lan + "bridge100: flags=8a63\n\tinet #{gateway} netmask 0xfffffffc\n\tmember: vmenet0 flags=3\n"
      assert_equal expected, AgentVM.blocked_networks(interfaces)
    end
    assert_equal AgentVM::PRIVATE_NETS, AgentVM.blocked_networks("inet 127.0.0.1 netmask 0xff000000\n")
  end
  def test_connected_subnet_extending_outside_private_range_remains_blocked
    blocks = AgentVM.blocked_networks("inet 192.168.50.2 netmask 0xff000000\n")
    assert_includes blocks, '192.0.0.0/8'
    assert_empty AgentVM::PRIVATE_NETS - blocks
  end
  def test_status_reads_process_lock_without_opening_disk_images
    previous = ENV['TART_HOME']
    ENV['TART_HOME'] = File.join(@tmp, 'tart-store')
    vm = AgentVM::VM.new(@config)
    FileUtils.mkdir_p(vm.tart_directory)
    path = File.join(vm.tart_directory, 'config.json')
    File.write(path, '{}')
    refute vm.running?
    input, output = IO.pipe
    child = fork do
      input.close
      File.open(path, 'r+') do |file|
        file.fcntl(Fcntl::F_SETLK, [0,0,0,Fcntl::F_WRLCK,0].pack('q!q!i!s!s!'))
        output.write('ready'); output.close
        sleep 30
      end
    end
    output.close
    assert_equal 'ready', input.read
    assert_equal child, vm.running_pid
    assert vm.running?
  ensure
    Process.kill('TERM', child) if child
    Process.wait(child) if child
    input.close if input && !input.closed?
    ENV['TART_HOME'] = previous
  end
end
