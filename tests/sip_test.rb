require 'minitest/autorun'
require 'minitest/mock'
require_relative '../lib/ui'

class SIPTest < Minitest::Test
  class Guest
    attr_accessor :policy, :model
    attr_reader :calls
    def initialize
      @policy='off'; @model='VirtualMac2,1'; @calls=[]
    end
    def running?; true; end
    def config; {'user'=>'developer'}; end
    def password; 'test-password'; end
    def ssh(*args, **)
      return model if args.include?('hw.model')
      "System Integrity Protection status: #{policy=='on' ? 'enabled' : 'disabled'}."
    end
    def root(*); @calls << :authenticated; end
    def with_lifecycle_lock; @calls << :locked; yield; end
    def stop_unlocked; @calls << :stopped; end
    def launch_unlocked(**); @calls << :normal_boot; end
    def wait_for(*); yield; end
    def start; @calls << :ready; end
  end
  def exercise(guest, changed:)
    gui=Object.new
    gui.define_singleton_method(:active?) { false }
    build=Object.new
    build.define_singleton_method(:install) { '/unused/test-tart' }
    recovery=Object.new
    recovery.define_singleton_method(:open) do |network:, &block|
      raise 'SIP enable requires the isolated signing connection' unless network
      guest.policy='on' if changed
      raise AgentVM::Error, 'Recovery confirmation not recognized'
    end
    AgentVM::GUI.stub(:new,gui) do
      AgentVM::UIBuild.stub(:new,build) do
        AgentVM::Recovery.stub(:new,recovery) { capture_io { AgentVM::SIP.new(guest).command(['on']) } }
      end
    end
  end
  def test_normal_boot_verifies_policy_even_after_a_recovery_navigation_error
    guest=Guest.new
    output,=exercise(guest,changed:true)
    assert_includes output, 'enabled (verified in normal macOS)'
    assert_equal [:authenticated,:locked,:stopped,:normal_boot,:ready], guest.calls
    guest=Guest.new
    error=assert_raises(AgentVM::Error) { exercise(guest,changed:false) }
    assert_includes error.message, 'expected on, observed off'
    assert_includes guest.calls, :normal_boot
  end
  def test_hardware_guard_refuses_host_before_recovery_or_sudo
    guest=Guest.new
    guest.model='Mac14,12'
    assert_raises(AgentVM::Error) { exercise(guest,changed:true) }
    assert_empty guest.calls
  end
end
