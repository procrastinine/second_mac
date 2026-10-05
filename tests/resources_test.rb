require 'minitest/autorun'
require_relative '../lib/resources'

class ResourcesTest < Minitest::Test
  def layout(total, main, recovery=5_000_000_000)
    {'Size Info'=>{'Total Bytes'=>total}, 'Partitions'=>[
      {'content-hint'=>'Apple_APFS','total-space'=>main},
      {'content-hint'=>'Apple_APFS_Recovery','total-space'=>recovery}
    ]}
  end

  def test_growth_must_reach_main_filesystem_and_preserve_recovery
    before = layout(100_000_000_000, 94_000_000_000)
    AgentVM::Resources.verify_growth(before, layout(120_000_000_000,114_000_000_000), 120_000_000_000)
    assert_raises(AgentVM::Error) do
      AgentVM::Resources.verify_growth(before, layout(120_000_000_000,94_000_000_000,25_000_000_000),120_000_000_000)
    end
    assert_raises(AgentVM::Error) do
      AgentVM::Resources.verify_growth(before, layout(120_000_000_000,114_000_000_000,0),120_000_000_000)
    end
    assert_raises(AgentVM::Error) do
      AgentVM::Resources.verify_growth(before, before,120_000_000_000)
    end
  end

  def test_ambiguous_disk_layout_fails_closed
    info = layout(100_000_000_000,94_000_000_000)
    info['Partitions'] << info['Partitions'].first.dup
    assert_raises(AgentVM::Error) { AgentVM::Resources.partition_size(info,'Apple_APFS') }
  end

  def test_bad_arguments_do_not_touch_vm
    resource = AgentVM::Resources.new(nil)
    [%w[--cpus nope], %w[--disk 150 extra], %w[--json --memory 8]].each do |args|
      assert_raises(AgentVM::Error) { resource.command(args) }
    end
  end
end
