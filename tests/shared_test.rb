require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/shared'

class SharedTest < Minitest::Test
  def with_share
    Dir.mktmpdir('agent-vm-share-') do |directory|
      vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('name'=>'share-fixture', 'share'=>directory))
      vm.define_singleton_method(:running?) { false }
      shared = AgentVM::Shared.new(vm)
      shared.define_singleton_method(:system) { |*args, **options| true }
      yield shared
    end
  end

  def test_owner_watcher_unmount_race_is_already_successful
    with_share do |shared|
      checks = [true, false]
      shared.define_singleton_method(:mounted?) { checks.shift }
      AgentVM.stub(:run, lambda { |*args, **options| raise AgentVM::Error, 'not currently mounted' }) do
        shared.stop
      end
      assert_empty checks
    end
  end

  def test_unmount_error_is_not_hidden_when_mount_remains
    with_share do |shared|
      shared.define_singleton_method(:mounted?) { true }
      AgentVM.stub(:run, lambda { |*args, **options| raise AgentVM::Error, 'busy' }) do
        assert_raises(AgentVM::Error) { shared.stop }
      end
    end
  end
end
