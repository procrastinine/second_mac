require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/live-shares'

class LiveSharesTest < Minitest::Test
  def test_failed_guest_remount_restores_previous_host_grants_without_restarting
    Dir.mktmpdir('live-share-rollback-') do |dir|
      previous = ENV['AGENT_VM_HOME']
      ENV['AGENT_VM_HOME'] = dir
      vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('share'=>File.join(dir,'old'), 'sharing'=>'native'))
      vm.define_singleton_method(:running?) { true }
      vm.define_singleton_method(:running_pid) { 123 }
      vm.define_singleton_method(:start) { raise 'Must not reboot on failure' }
      vm.define_singleton_method(:stop) { raise 'Must not stop on failure' }
      vm.save
      original=vm.config.dup
      candidate=AgentVM.validate(original.merge('share'=>File.join(dir,'new')))
      installer=Object.new
      installer.define_singleton_method(:sharing_tools) { }
      installer.define_singleton_method(:sharing_directories) { |_| }
      runtime=Object.new
      runtime.define_singleton_method(:current) { {'features'=>['live-shares']} }
      shared=Object.new
      shared.define_singleton_method(:prepare) { }
      shared.define_singleton_method(:owner) { |_| }
      shared.define_singleton_method(:stop_host) { |**| }
      changes=[]
      transaction=AgentVM::LiveShares.new(vm)
      transaction.define_singleton_method(:attach) { |config| changes << config['share'] }
      transaction.define_singleton_method(:detach) { changes << :detached }
      transaction.define_singleton_method(:guest) do |action, config=nil|
        if action=='apply' && config['share']==candidate['share']
          concurrent = AgentVM::VM.load(vm.name)
          concurrent.config['network_mode'] = 'off'
          concurrent.save
          raise AgentVM::Error, 'new guest mount failed'
        end
      end
      AgentVM::Installer.stub(:new,installer) do
        AgentVM::Runtime.stub(:new,runtime) do
          AgentVM::Shared.stub(:new,shared) do
            assert_raises(AgentVM::Error) { transaction.change(candidate) }
          end
        end
      end
      assert_equal original.merge('network_mode'=>'off'), vm.config
      assert_equal original['share'], JSON.parse(File.read(vm.file('config.json')))['share']
      assert_equal [:detached,candidate['share'],:detached,original['share']],changes
      refute File.exist?(transaction.marker)
      assert_equal original['share'], JSON.parse(File.read(vm.file('access-launch.json')))['shares'].first['host']
    ensure
      ENV['AGENT_VM_HOME'] = previous
    end
  end
end
