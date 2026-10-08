require 'minitest/autorun'
require 'minitest/mock'
require_relative '../guest/network-dns'

class NetworkDNSTest < Minitest::Test
  QUAD9 = %w[9.9.9.9 149.112.112.112].freeze
  def setup
    @calls = []
    @saved = QUAD9.dup
    @effective = @saved.dup
    @router = '10.47.29.97'
    @next_router = '172.24.158.169'
    @order = "An asterisk (*) denotes that a network service is disabled.\n" \
             "(1) VM Ethernet\n(Hardware Port: Ethernet, Device: en0)\n" \
             "(2) Other Ethernet\n(Hardware Port: Ethernet, Device: en1)\n"
  end
  def command(*args)
    @calls << args
    command = args[1]
    case command
    when '-listnetworkserviceorder' then @order
    when '-listallnetworkservices' then "An asterisk (*) denotes that a network service is disabled.\nVM Ethernet\n*Disabled\n"
    when '-getdnsservers' then @saved.empty? ? "There aren't any DNS Servers set on VM Ethernet." : @saved.join("\n")
    when '-setdnsservers'
      @saved = args[3..-1] == ['empty'] ? [] : args[3..-1]
      @effective = @saved.empty? ? [@router] : @saved.dup
      ''
    when '-setv4off'
      @router = ''
      @effective = []
      ''
    when '-setdhcp'
      @router = @next_router
      @effective = @saved.empty? ? [@router] : @saved.dup
      ''
    else flunk "Unexpected network mutation: #{args.inspect}"
    end
  end
  def apply(**options)
    MacNetworkDNS.stub(:run, method(:command)) do
      MacNetworkDNS.stub(:router, -> { @router }) { MacNetworkDNS.apply(**options) }
    end
  end
  def test_unchanged_native_settings_do_not_cycle_the_interface
    apply(backend:'native')
    assert_equal QUAD9, @effective
    assert_equal %w[-listallnetworkservices -getdnsservers], @calls.map { |call| call[1] }
  end
  def test_renewal_keeps_saved_dns_on_the_managed_service
    apply(backend:'native', renew:true)
    assert_equal @next_router, @router
    assert_equal QUAD9, @effective
    assert_equal [%w[/usr/sbin/networksetup -setv4off VM\ Ethernet],
                  %w[/usr/sbin/networksetup -setdhcp VM\ Ethernet]],
                 @calls.select { |call| %w[-setv4off -setdhcp].include?(call[1]) }
    refute @calls.any? { |call| call[0] == '/usr/sbin/ipconfig' }
  end
  def test_vpn_renewal_uses_router_dns_and_native_restores_quad9
    @next_router = '192.168.127.1'
    apply(backend:'vpn', renew:true)
    assert_empty @saved
    assert_equal ['192.168.127.1'], @effective
    @next_router = '192.168.46.201'
    apply(backend:'native', renew:true)
    assert_equal QUAD9, @saved
    assert_equal QUAD9, @effective
  end
  def test_missing_ethernet_service_does_not_change_another_interface
    @order = "(1) Other Ethernet\n(Hardware Port: Ethernet, Device: en1)\n"
    assert_raises(RuntimeError) { apply(backend:'native', renew:true) }
    assert_equal QUAD9, @effective
    refute @calls.any? { |call| call[1].start_with?('-set') }
  end
  def test_disabled_ethernet_does_not_reuse_the_preceding_service_name
    @order = "(1) VM Ethernet\n(Hardware Port: Ethernet, Device: en1)\n" \
             "(*) Disabled\n(Hardware Port: Ethernet, Device: en0)\n"
    assert_raises(RuntimeError) { apply(backend:'native', renew:true) }
    refute @calls.any? { |call| call[1].start_with?('-set') }
  end
  def test_failed_lease_teardown_still_restores_dhcp
    MacNetworkDNS.stub(:wait_for, -> { raise 'Guest configuration busy' }) do
      assert_raises(RuntimeError) { apply(backend:'native', renew:true) }
    end
    assert_equal '-setdhcp', @calls.last[1]
    assert_equal QUAD9, @effective
  end
end
