require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/build-cache'

class BuildCacheTest < Minitest::Test
  def test_cleanup_retains_current_and_pinned_builds_without_touching_disks_or_finished_runtimes
    Dir.mktmpdir('compiler-cache-') do |dir|
      previous = ENV['AGENT_VM_HOME']
      ENV['AGENT_VM_HOME'] = dir
      cache = AgentVM::BuildCache.new
      old = File.join(cache.root, 'source-2.40.0', '.build')
      current = File.join(cache.root, 'source-2.40.1', '.build')
      pinned = File.join(cache.root, '2.39.0-1234567890abcdef', '.build')
      [old, current, pinned].each { |path| AgentVM.write(File.join(path, 'object'), 'compiler output') }
      binary = File.join(cache.root, '2.40.0-1234567890abcdef', 'tart')
      AgentVM.write(binary, 'keep finished runtime')
      disk = File.join(dir, 'disk.img')
      AgentVM.write(disk, 'keep guest disk')
      saved_files = %w[box/state.vzvmsave box/snapshots/before-change/vm/disk.img copy/disk.img]
      saved_files.each { |path| AgentVM.write(File.join(dir, path), 'keep saved state') }
      AgentVM.json_write(File.join(dir, 'box/config.json'), {'tart_version'=>'2.40.1'})
      AgentVM.json_write(File.join(dir, 'box/suspend.json'), {'binary'=>File.join(pinned, 'object')})
      capture_io { cache.clean }
      refute File.exist?(old)
      assert File.directory?(current)
      assert File.directory?(pinned)
      assert_equal 'keep finished runtime', File.read(binary)
      assert_equal 'keep guest disk', File.read(disk)
      saved_files.each { |path| assert_equal 'keep saved state', File.read(File.join(dir, path)) }
    ensure
      ENV['AGENT_VM_HOME'] = previous
    end
  end

  def test_unreadable_reference_inventory_preserves_obsolete_cache
    Dir.mktmpdir('compiler-cache-') do |dir|
      previous = ENV['AGENT_VM_HOME']
      ENV['AGENT_VM_HOME'] = dir
      cache = AgentVM::BuildCache.new
      old = File.join(cache.root, 'source-2.40.0', '.build', 'object')
      AgentVM.write(old, 'compiler output')
      AgentVM.write(File.join(dir, 'box/suspend.json'), '{incomplete')
      error = assert_raises(AgentVM::Error) { cache.clean }
      assert_match(/Cannot inspect all runtime references/, error.message)
      assert_equal 'compiler output', File.read(old)
    ensure
      ENV['AGENT_VM_HOME'] = previous
    end
  end
end
