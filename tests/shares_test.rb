require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/shares-cli'
require_relative '../lib/shared'

class SharesTest < Minitest::Test
  def setup
    @tmp = File.realpath(Dir.mktmpdir('second-mac-shares-'))
    @previous = ENV['AGENT_VM_HOME']
    ENV['AGENT_VM_HOME'] = File.join(@tmp, 'state')
    @config = AgentVM.validate(AgentVM::DEFAULTS.merge('share'=>File.join(@tmp, 'writable'), 'tart'=>'/fake/tart'))
    AgentVM.share_entries(@config).each { |entry| FileUtils.mkdir_p(entry['host']) }
  end
  def teardown
    ENV['AGENT_VM_HOME'] = @previous
    FileUtils.remove_entry(@tmp)
  end
  def test_native_folders_bypass_projection_and_readonly_is_enforced_at_attachment
    vm = AgentVM::VM.new(@config)
    args = vm.run_args.grep(/^--dir=/)
    assert_equal ["--dir=#{@config['share']}:tag=agent-files",
                  "--dir=#{@config['read_only_share']}:tag=agent-readonly,ro",
                  "--dir=#{vm.file('shared-view')}:tag=agent-linked"], args
    rows = AgentVM.shares(@config)
    assert_equal [false, true, false], rows.map { |entry| entry['read_only'] }
    assert_equal %w[native native macfuse], rows.map { |entry| entry['kind'] }
    refute_includes JSON.generate(AgentVM.guest_config(@config)), @tmp
  end
  def test_configurable_names_and_paths_are_independent_of_host_account
    config = AgentVM.validate(@config.merge('guest_share'=>'work', 'guest_read_only_share'=>'reference',
      'guest_linked_share'=>'projects', 'linked_share'=>File.join(@tmp, 'selected projects')))
    guest = AgentVM.guest_config(config)
    assert_equal %w[work reference projects], AgentVM.share_entries(guest).map { |entry| entry['name'] }
    assert AgentVM.share_entries(guest).all? { |entry| entry['host'].start_with?('/Volumes/') }
    refute_includes JSON.generate(guest), @tmp
  end
  def test_hybrid_without_linked_folder_keeps_both_native_mounts_and_needs_no_host_projection
    vm = AgentVM::VM.new(@config.merge('linked_files'=>false))
    assert_equal %w[agent-files agent-readonly], AgentVM.share_entries(vm.config).map { |row| row['tag'] }
    assert_equal ["--dir=#{@config['share']}:tag=agent-files", "--dir=#{@config['read_only_share']}:tag=agent-readonly,ro"], vm.run_args.grep(/^--dir=/)
    guest = AgentVM.guest_config(vm.config)
    assert_equal false, guest['linked_files']
    assert_equal %w[shared_files readonly_files], AgentVM.share_entries(guest).map { |row| row['name'] }
    AgentVM.stub(:run, ->(*, **_) { flunk 'Native sharing must not install host dependencies' }) do
      AgentVM::Installer.new(vm.config).sharing_tools
    end
    shared = AgentVM::Shared.new(vm)
    shared.define_singleton_method(:mounted?) { raise 'Must not depend on a macFUSE mount' }
    assert_equal @config['share'], shared.prepare
    calls = []
    vm.stub(:running?, true) do
      vm.stub(:root, ->(*args, **_) { calls << args }) { shared.start }
    end
    assert_equal '/usr/local/libexec/agent-vm/mount-share.rb', calls.first.last
    shared.owner(123)
    refute File.exist?(vm.file('share-owner.json'))
  end
  def test_overlapping_or_colliding_folders_are_rejected
    [@config['share'], File.join(@config['share'], 'nested')].each do |path|
      assert_raises(AgentVM::Error) { AgentVM.validate(@config.merge('linked_share'=>path)) }
    end
    %w[SHARED_FILES Documents ../escape].each do |name|
      assert_raises(AgentVM::Error) { AgentVM.validate(@config.merge('guest_linked_share'=>name)) }
    end
    alias_path = File.join(@tmp, 'alias')
    File.symlink(@config['share'], alias_path)
    config = AgentVM.validate(@config.merge('linked_share'=>alias_path))
    assert_raises(AgentVM::Error) { AgentVM.shares(config) }
  end
  def test_existing_macfuse_configuration_remains_one_projected_folder
    config = @config.merge('sharing'=>'macfuse')
    vm = AgentVM::VM.new(config)
    assert_equal ["--dir=#{vm.file('shared-view')}:tag=agent-files"], vm.run_args.grep(/^--dir=/)
    assert_equal 1, AgentVM.shares(config).length
  end
  def test_disabled_mode_exports_nothing_even_with_all_three_paths_saved
    vm = AgentVM::VM.new(@config.merge('sharing'=>'none'))
    assert_empty vm.run_args.grep(/^--dir=/)
    assert_empty AgentVM.shares(vm.config)
  end
  def test_share_change_cannot_modify_a_running_vm_or_enable_a_throwaway
    vm = AgentVM::VM.new(@config)
    vm.save
    before = File.read(vm.file('config.json'))
    vm.stub(:running?, true) do
      assert_raises(AgentVM::Error) { AgentVM::ShareSettings.new(vm).command(%w[configure --sharing none]) }
    end
    assert_equal before, File.read(vm.file('config.json'))
    vm.config['throwaway'] = {'id'=>'deadbeef'}
    assert_raises(AgentVM::Error) { AgentVM::ShareSettings.new(vm).command(%w[configure --sharing hybrid]) }
  end

  def test_open_file_check_ignores_only_spotlights_read_only_volume_monitor
    mount='/Volumes/work'
    monitor="p124\ncmds\nf25\nar\ntDIR\nn#{mount}\n"
    refute AgentVM.busy_share_handles?(monitor, mount)
    assert AgentVM.busy_share_handles?(monitor.sub('ar','aw'), mount)
    assert AgentVM.busy_share_handles?(monitor.sub('f25','fcwd'), mount)
    assert AgentVM.busy_share_handles?(monitor.sub('cmds','cruby'), mount)
    assert AgentVM.busy_share_handles?(monitor.sub("n#{mount}","n#{mount}/project"), mount)
    assert AgentVM.busy_share_handles?(monitor+"p456\ncruby\nf3\nar\ntREG\nn#{mount}/file\n", mount)
    assert AgentVM.busy_share_handles?('lsof: unexpected error', mount)
  end
end
