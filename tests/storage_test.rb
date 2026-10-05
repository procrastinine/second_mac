require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/backups'
require_relative '../lib/images'

class StorageTest < Minitest::Test
  class FixtureVM < AgentVM::VM
    def render_host(**_options); end
    def exclude_backup(*_args); end
  end
  def setup
    @directory = File.realpath(Dir.mktmpdir('agent-vm-storage-'))
    @old_state, @old_tart = ENV['AGENT_VM_HOME'], ENV['TART_HOME']
    ENV['AGENT_VM_HOME'], ENV['TART_HOME'] = File.join(@directory, 'state'), File.join(@directory, 'tart')
    @vm = FixtureVM.new(AgentVM::DEFAULTS.merge('name'=>'storage-test', 'user'=>'builder', 'phase'=>'ready', 'share'=>File.join(@directory, 'share'), 'tart'=>'/fake/tart',
      'restore_image'=>{'url'=>'https://example.invalid/restore.ipsw', 'version'=>'27.0.1', 'build'=>'26A434'}))
    AgentVM.share_entries(@vm.config).each { |entry| FileUtils.mkdir_p(entry['host']) }
    FileUtils.mkdir_p(@vm.tart_directory)
    %w[config.json disk.img nvram.bin].each { |name| File.write(File.join(@vm.tart_directory, name), name + '-original') }
    %w[admin-password id_ed25519 id_ed25519.pub].each { |name| AgentVM.write(@vm.file(name), 'test-only-' + name) }
    AgentVM.write(@vm.file('known-hosts'), "storage-test ssh-ed25519 fixture\n")
    @vm.save
    @backups = AgentVM::Backups.new(@vm)
  end
  def teardown
    ENV['AGENT_VM_HOME'], ENV['TART_HOME'] = @old_state, @old_tart
    FileUtils.remove_entry(@directory)
  end
  def snapshot
    path = @backups.snapshot_path('checkpoint')
    capture_io { @backups.stopped { @backups.create(path) } }
    path
  end
  def test_snapshot_is_independent_and_restore_preserves_host_grants
    path = snapshot
    disk = File.join(@vm.tart_directory, 'disk.img')
    File.write(disk, 'new guest content')
    File.write(File.join(@vm.config['share'], 'project'), 'host work')
    @vm.config['ports'] = [{'direction'=>'host', 'source'=>1234}]
    @vm.save
    capture_io { @backups.restore(path) }
    assert_equal 'disk.img-original', File.read(disk)
    assert_equal 'host work', File.read(File.join(@vm.config['share'], 'project'))
    assert_equal 1234, @vm.config['ports'].first['source']
    previous = Dir.glob(File.join(@backups.root, 'before-restore-*')).fetch(0)
    assert_equal 'new guest content', File.read(File.join(previous, 'vm/disk.img'))
    refute File.exist?(@vm.file('restore-in-progress.json'))
    assert_equal 0600, File.stat(File.join(path, 'identity/id_ed25519')).mode & 0777
  end
  def test_corrupt_backup_and_symlink_manifest_are_rejected_before_replacement
    path = snapshot
    File.write(File.join(path, 'vm/disk.img'), 'damaged')
    assert_raises(AgentVM::Error) { @backups.restore(path) }
    assert_equal 'disk.img-original', File.read(File.join(@vm.tart_directory, 'disk.img'))
    File.rename(File.join(path, 'manifest.json'), File.join(path, 'other.json'))
    File.symlink('other.json', File.join(path, 'manifest.json'))
    assert_raises(AgentVM::Error) { @backups.verify(path) }
    capture_io { @backups.command(['delete', 'checkpoint']) }
    refute File.exist?(path)
  end
  def test_restore_failure_rolls_back_and_keeps_checkpoint
    path = snapshot
    File.write(File.join(@vm.tart_directory, 'disk.img'), 'pre-restore')
    calls = 0
    original = @backups.method(:replace)
    @backups.define_singleton_method(:replace) do |*args|
      original.call(*args)
      calls += 1
      raise AgentVM::Error, 'injected post-rename failure' if calls == 1
    end
    capture_io { assert_raises(AgentVM::Error) { @backups.restore(path) } }
    assert_equal 'pre-restore', File.read(File.join(@vm.tart_directory, 'disk.img'))
    refute File.exist?(@vm.file('restore-in-progress.json'))
  end
  def test_recovery_works_if_interruption_left_live_directory_missing
    snapshot
    AgentVM.json_write(@vm.file('restore-in-progress.json'), {'before'=>'checkpoint'})
    File.rename(@vm.tart_directory, @vm.tart_directory + '-interrupted')
    capture_io { @backups.recover }
    assert_equal 'disk.img-original', File.read(File.join(@vm.tart_directory, 'disk.img'))
    refute File.exist?(@vm.file('restore-in-progress.json'))
  end
  def test_external_backup_can_restore_a_lost_vm_disk
    path = snapshot
    FileUtils.remove_entry(@vm.tart_directory)
    capture_io { @backups.restore(path) }
    assert_equal 'disk.img-original', File.read(File.join(@vm.tart_directory, 'disk.img'))
    refute File.exist?(@vm.file('restore-in-progress.json'))
  end
  def test_backup_must_be_outside_shared_files_and_live_disk
    AgentVM.share_entries(@vm.config).each do |entry|
      assert_raises(AgentVM::Error) { @backups.stopped { @backups.create(File.join(entry['host'], 'private')) } }
    end
    assert_raises(AgentVM::Error) { @backups.snapshot_path('../escape') }
    File.write(File.join(@vm.tart_directory, 'state.vzvmsave'), 'suspended')
    assert_raises(AgentVM::Error) { @backups.stopped { flunk 'Copied suspended disk' } }
  end
  def test_disk_lock_blocks_a_concurrent_runner
    AgentVM::DiskFiles.with_lock(@vm.tart_directory) do
      input, output = IO.pipe
      child = fork do
        input.close
        begin
          AgentVM::DiskFiles.with_lock(@vm.tart_directory) { output.write('wrong') }
        rescue AgentVM::Error
          output.write('blocked')
        end
        output.close
        exit! 0
      end
      output.close
      assert_equal 'blocked', input.read
      input.close
      Process.wait(child)
    end
  end
  def test_pristine_cache_reuse_verifies_content_and_never_copies_credentials
    images = AgentVM::Images.new(@vm)
    assert_raises(AgentVM::Error) { images.cache }
    @vm.config['phase'] = 'creating'
    capture_io { images.cache }
    manifest = images.reusable
    refute_nil manifest
    refute File.exist?(File.join(File.dirname(manifest), 'identity'))
    destination = FixtureVM.new(@vm.config.merge('name'=>'new-box'))
    target = AgentVM::Images.new(destination)
    calls = []
    AgentVM.stub(:run, lambda { |*args, **_options| calls << args; '27.0.1' }) do
      capture_io { assert target.reuse }
    end
    assert_equal 'disk.img-original', File.read(File.join(destination.tart_directory, 'disk.img'))
    assert calls.any? { |args| args.include?('--random-mac') && args.include?('--random-serial') }
    refute File.exist?(destination.file('admin-password'))
    File.write(File.join(File.dirname(manifest), 'disk.img'), 'corrupt')
    another = FixtureVM.new(@vm.config.merge('name'=>'another-box'))
    capture_io { assert_raises(AgentVM::Error) { AgentVM::Images.new(another).reuse } }
    refute File.exist?(another.tart_directory)
    assert_nil AgentVM::Images.new(@vm.tap { |v| v.config['fresh'] = true }).reusable
  end
  def test_explicit_clone_copies_credentials_but_keeps_new_host_grants
    destination = FixtureVM.new(@vm.config.merge('name'=>'copy-box', 'share'=>File.join(@directory, 'separate-share')))
    capture_io { AgentVM::Images.new(destination).clone_managed(@vm.name) }
    assert_equal File.read(@vm.file('admin-password')), File.read(destination.file('admin-password'))
    assert File.read(destination.file('known-hosts')).start_with?('copy-box ')
    assert_equal File.join(@directory, 'separate-share'), destination.config['share']
  end

  def test_latest_selection_is_recorded_for_resume_and_only_matching_bases_are_reused
    images = AgentVM::Images.new(@vm)
    @vm.config['phase'] = 'creating'
    capture_io { images.cache }
    old_manifest = images.reusable
    old = JSON.parse(File.read(old_manifest))
    fresh = FixtureVM.new(@vm.config.merge('name'=>'latest-box').reject { |key, _| key == 'restore_image' })
    latest = {'url'=>'https://example.invalid/new.ipsw', 'version'=>'27.0.2', 'build'=>'26A500'}
    target = AgentVM::Images.new(fresh)
    AgentVM::RestoreImage.stub(:latest, latest) do
      capture_io { assert_nil target.reusable }
    end
    AgentVM::RestoreImage.stub(:latest, -> { flunk 'Resume queried a different image instead of its saved download' }) do
      resumed = AgentVM::Images.new(AgentVM::VM.load(fresh.name))
      assert_equal latest['url'], resumed.restore_source
    end
    old['restore_image'] = latest
    AgentVM.json_write(old_manifest, old)
    assert_equal old_manifest, target.reusable
    old.delete('restore_image')
    old['format'] = 1
    AgentVM.json_write(old_manifest, old)
    assert_nil target.reusable, 'a legacy cache cannot prove it is the latest build'
    refute File.exist?(fresh.tart_directory), 'metadata lookup must not create/download an OS'
    assert_raises(AgentVM::Error) { AgentVM::RestoreImage.validate(latest.merge('url'=>'http://example.invalid/image')) }
  end

  def test_local_restore_metadata_uses_existing_ipsw_and_survives_resume
    path = File.join(@directory, 'existing restore.ipsw')
    metadata = {'url'=>'file://' + path.gsub(' ', '%20'), 'version'=>'26.6.0', 'build'=>'25G100'}
    config = @vm.config.merge('name'=>'local-image', 'ipsw'=>path).reject { |key, _| key == 'restore_image' }
    vm = FixtureVM.new(config)
    AgentVM::RestoreImage.stub(:local, lambda { |selected| assert_equal path, selected; metadata }) do
      AgentVM::RestoreImage.stub(:latest, -> { flunk 'Fetched another macOS image' }) do
        capture_io { assert_equal path, AgentVM::Images.new(vm).restore_source }
      end
    end
    AgentVM::RestoreImage.stub(:local, ->(*) { flunk 'Reopened the IPSW after saving its metadata' }) do
      restored = AgentVM::Images.new(AgentVM::VM.load(vm.name))
      assert_equal path, restored.restore_source
      assert_equal metadata, restored.restore_image
    end
    assert_raises(AgentVM::Error) { AgentVM::RestoreImage.validate(metadata) }
    assert_raises(AgentVM::Error) { AgentVM::RestoreImage.validate(metadata.merge('url'=>'file://remote.invalid/image'), local:true) }
  end

  def test_explicit_https_image_does_not_trigger_another_metadata_download
    url = 'https://example.invalid/selected.ipsw'
    vm = FixtureVM.new(@vm.config.merge('ipsw'=>url).reject { |key, _| key == 'restore_image' })
    AgentVM::RestoreImage.stub(:latest, -> { flunk 'Ignored explicit image selection' }) do
      AgentVM::RestoreImage.stub(:local, ->(*) { flunk 'Tried to inspect a URL as a local image' }) do
        assert_equal url, AgentVM::Images.new(vm).restore_source
        assert_nil AgentVM::Images.new(vm).restore_image
      end
    end
  end
end
