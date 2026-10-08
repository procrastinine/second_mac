require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/network'

class NetworkTest < Minitest::Test
  def setup
    @environment = ENV.to_h
    @directory = Dir.mktmpdir('network-selection-')
    ENV['AGENT_VM_HOME'] = @directory
    @vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('name'=>'network-box', 'phase'=>'ready'))
    @network = AgentVM::Network.new(@vm)
  end
  def teardown
    ENV.replace(@environment)
    FileUtils.remove_entry(@directory)
  end
  def test_native_launch_keeps_original_network_path_and_never_builds_a_proxy
    @network.define_singleton_method(:build) { flunk 'Native networking must not add a userspace proxy' }
    AgentVM.stub(:run, " interface: en0\n") { capture_io { @network.prepare } }
    assert_equal 'native', @network.state['backend']
    assert_equal 'native', @network.environment['SECOND_MAC_NETWORK_BACKEND']
    assert_equal @vm.control_socket('network'), @network.environment['SECOND_MAC_NETWORK_SOCKET']
    assert_equal File.expand_path('../lib/network-bin', __dir__) + ':' + AgentVM::Network::PATH, @network.environment['PATH']
    refute @network.environment.key?('SECOND_MAC_NETWORK_BINARY')
  end
  def test_vpn_route_selects_isolated_helper_but_never_exposes_bootstrap_ssh_after_setup
    binary = File.join(@directory, 'bin/softnet')
    AgentVM.write(binary, '#!/bin/sh', 0700)
    @network.define_singleton_method(:build) { binary }
    AgentVM.stub(:run, " interface: utun8\n") { capture_io { @network.prepare } }
    assert_equal 'vpn', @network.state['backend']
    assert_equal binary, @network.environment['SECOND_MAC_NETWORK_BINARY']
    refute @network.environment.key?('SECOND_MAC_BOOTSTRAP_PORT')
    assert_empty @vm.config.keys.grep(/vpn.*key|vpn.*token/)
  end
  def test_unknown_route_never_silently_selects_native_egress
    AgentVM.stub(:run, ->(*) { raise AgentVM::Error, 'No route' }) { assert_equal 'vpn', @network.desired }
    @vm.config['network_mode'] = 'native'
    AgentVM.stub(:run, ->(*) { flunk 'Explicit selection should not probe the network' }) { assert_equal 'native', @network.desired }
  end
  def test_live_switch_preserves_vm_process_and_does_not_restart_services
    @vm.define_singleton_method(:running?) { true }
    @vm.define_singleton_method(:running_pid) { 123 }
    @vm.define_singleton_method(:stop) { flunk 'Live switch must not stop macOS' }
    @vm.define_singleton_method(:start) { flunk 'Live switch must not restart macOS' }
    calls = []
    @network.define_singleton_method(:build) { '/private/network-helper' }
    @network.define_singleton_method(:request) do |value|
      calls << value
      {'pid'=>123, 'live_switch'=>true, 'backend'=>value['backend'] || 'native'}
    end
    @network.define_singleton_method(:configure_dns) { |**value| calls << value }
    @network.define_singleton_method(:start_watcher) { }
    AgentVM.stub(:run, '') { capture_io { @network.command(['vpn']) } }
    assert_equal 'vpn', @vm.config['network_mode']
    assert_equal 'network-set', calls[1]['op']
    assert_equal({renew:true}, calls.last)
    assert_equal 123, @network.state['owner']
  end
  def test_old_running_controller_requires_one_time_activation_without_silently_rebooting
    @vm.define_singleton_method(:running?) { true }
    @network.define_singleton_method(:request) { |*| {'pid'=>123} }
    @network.define_singleton_method(:build) { '/private/network-helper' }
    assert_raises(AgentVM::Error) { @network.command(['vpn']) }
    assert_equal 'auto', @vm.config['network_mode']
  end
  def test_lan_changes_renew_dhcp_once_after_replacing_helper_without_reboot
    @vm.config['network_mode'] = 'native'
    @vm.define_singleton_method(:running?) { true }
    @vm.define_singleton_method(:running_pid) { 123 }
    @vm.define_singleton_method(:stop) { flunk 'A LAN change must not reboot the guest' }
    before = "inet 198.51.100.4 netmask 0xffffff00\n"
    after = "inet 203.0.113.8 netmask 0xffffff00\n"
    controller = {'pid'=>123, 'live_switch'=>true, 'backend'=>'native', 'healthy'=>true,
      'blocks'=>AgentVM.blocked_networks(before).join(',')}
    AgentVM.json_write(@vm.file('network-state.json'), {'backend'=>'native', 'owner'=>123})
    switches = []
    renewals = []
    @network.define_singleton_method(:request) do |value|
      if value['op'] == 'network-set'
        switches << value
        controller['blocks'] = value.fetch('blocks')
      end
      controller.dup
    end
    @network.define_singleton_method(:configure_dns) { |**value| renewals << value }
    AgentVM.stub(:run, before) { 2.times { @network.refresh(force:false) } }
    assert_empty switches
    assert_empty renewals
    AgentVM.stub(:run, after) { 2.times { @network.refresh(force:false) } }
    assert_equal 1, switches.size
    assert_equal [{renew:true}], renewals
    assert_includes switches.first.fetch('blocks').split(','), '203.0.113.0/24'
    refute_includes switches.first.fetch('blocks').split(','), '198.51.100.0/24'
    assert_equal 123, @network.state['owner']
  end
  def test_private_bridge_changes_never_restart_the_native_helper
    @vm.config['network_mode'] = 'native'
    @vm.define_singleton_method(:running?) { true }
    @vm.define_singleton_method(:running_pid) { 123 }
    lan = "en0: flags=8863\n\tinet 203.0.113.8 netmask 0xffffff00\n"
    controller = {'pid'=>123, 'live_switch'=>true, 'backend'=>'native', 'healthy'=>true,
      'blocks'=>AgentVM.blocked_networks(lan).join(',')}
    AgentVM.json_write(@vm.file('network-state.json'), {'backend'=>'native', 'owner'=>123})
    requests = []
    @network.define_singleton_method(:request) { |value| requests << value; controller.dup }
    @network.define_singleton_method(:configure_dns) { |**| raise 'Unchanged restrictions must preserve DHCP' }
    %w[10.47.29.97 172.24.158.169 192.168.46.201].each do |gateway|
      interfaces = lan + "bridge100: flags=8a63\n\tinet #{gateway} netmask 0xfffffffc\n"
      AgentVM.stub(:run, interfaces) { @network.refresh(force:false) }
    end
    assert_equal Array.new(3) { {'op'=>'network-status'} }, requests
  end
  def test_failed_dhcp_after_policy_change_retries_without_replacing_helper_again
    @vm.config['network_mode'] = 'native'
    @vm.define_singleton_method(:running?) { true }
    @vm.define_singleton_method(:running_pid) { 123 }
    controller = {'pid'=>123, 'live_switch'=>true, 'backend'=>'native', 'healthy'=>true, 'blocks'=>'@host'}
    AgentVM.json_write(@vm.file('network-state.json'), {'backend'=>'native', 'owner'=>123})
    switches, renewals = [], []
    @network.define_singleton_method(:request) do |value|
      if value['op'] == 'network-set'
        switches << value
        controller['blocks'] = value.fetch('blocks')
      end
      controller.dup
    end
    @network.define_singleton_method(:configure_dns) do |**value|
      renewals << value
      raise AgentVM::Error, 'Guest temporarily unavailable' if renewals.size == 1
    end
    AgentVM.stub(:run, '') do
      assert_raises(AgentVM::Error) { @network.refresh(force:false) }
      assert_equal true, @network.state['dns_pending']
      @network.refresh(force:false)
      @network.refresh(force:false)
    end
    assert_equal 1, switches.size
    assert_equal [{renew:true}, {renew:true}], renewals
    refute @network.state.key?('dns_pending')
  end
  def test_older_supervisor_learns_policy_once_without_restarting_each_poll
    @vm.config['network_mode'] = 'vpn'
    @vm.define_singleton_method(:running?) { true }
    @vm.define_singleton_method(:running_pid) { 123 }
    AgentVM.json_write(@vm.file('network-state.json'), {'backend'=>'vpn', 'owner'=>123})
    switches = []
    renewals = []
    @network.define_singleton_method(:build) { '/private/network-helper' }
    @network.define_singleton_method(:request) do |value|
      switches << value if value['op'] == 'network-set'
      {'pid'=>123, 'live_switch'=>true, 'backend'=>'vpn', 'healthy'=>true}
    end
    @network.define_singleton_method(:configure_dns) { |**value| renewals << value }
    AgentVM.stub(:run, '') { 3.times { @network.refresh(force:false) } }
    assert_equal 1, switches.size
    assert_equal [{renew:true}], renewals
    refute_empty @network.state.fetch('blocks')
  end
  def test_bootstrap_loopback_port_is_used_by_both_ssh_and_scp
    AgentVM.json_write(@vm.file('network-state.json'), {'backend'=>'vpn', 'bootstrap_port'=>43022})
    assert_equal ['127.0.0.1',43022], @network.bootstrap_endpoint
    assert_includes @vm.bootstrap_args('127.0.0.1'), 'Port=43022'
    assert_includes @vm.bootstrap_args('192.168.2.2'), 'Port=22'
  end
end
