require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/guest-update'
require_relative '../lib/install'
require_relative '../lib/permissions'
require_relative '../lib/camera'

class GuestUpdateTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('second-mac-reconcile-')
    @source = File.join(@tmp, 'source')
    %w[guest/control-client.rb guest/install-control.rb guest/camera-sink.m guest/camera-receiver.rb
       guest/configure.py lib/core.rb lib/profile-plan.rb lib/permissions.rb lib/autologin.rb
       lib/guest-update.rb lib/camera.rb].each { |name| AgentVM.write(File.join(@source, name), name) }
    AgentVM.write(File.join(@tmp, 'disk.img'), 'fixture disk')
    @payload = {'applied'=>{}, 'helpers'=>{}, 'camera_installed'=>false}
    @calls = []
    payload, calls, directory = @payload, @calls, @tmp
    @vm = Object.new
    config = AgentVM::DEFAULTS.merge('name'=>'test-box', 'user'=>'builder', 'phase'=>'ready')
    @vm.define_singleton_method(:config) { config }
    @vm.define_singleton_method(:tart_directory) { directory }
    @vm.define_singleton_method(:file) { |name| File.join(directory, name) }
    @vm.define_singleton_method(:ssh) { |*_, **_| calls << :probe; JSON.generate(payload) }
    @vm.define_singleton_method(:root) { |*_, **options| calls << :checkpoint; payload['applied'] = JSON.parse(options.fetch(:input)) }
    @update = AgentVM::GuestUpdate.new(@vm)
    source = @source
    @update.define_singleton_method(:source) { source }
    updater = @update
    @installer = Object.new
    @installer.define_singleton_method(:apply_configuration) do |_vm, **options|
      calls << [:configuration, options]
      payload['helpers'] = GuestUpdateTest.helpers(source)
      updater.record_configuration
    end
    @permissions = Object.new
    @permissions.define_singleton_method(:install_client) { calls << :helpers; payload['helpers'] = GuestUpdateTest.helpers(source) }
    @camera = Object.new
    @camera.define_singleton_method(:active?) { false }
    @camera.define_singleton_method(:install_helpers) { calls << :camera }
  end
  def teardown; FileUtils.remove_entry(@tmp); end
  def self.helpers(source)
    {'control-client.rb'=>'guest/control-client.rb', 'command'=>'guest/control-client.rb',
     'core.rb'=>'lib/core.rb', 'profile-plan.rb'=>'lib/profile-plan.rb'}.to_h do |name, path|
      [name, Digest::SHA256.file(File.join(source, path)).hexdigest]
    end
  end
  def sync
    AgentVM::Installer.stub(:new, @installer) do
      AgentVM::Permissions.stub(:new, @permissions) do
        AgentVM::Camera.stub(:new, @camera) { capture_io { @update.synchronize } }
      end
    end
  end
  def configuration_calls; @calls.grep(Array).select { |call| call.first == :configuration }; end

  def test_multiple_updates_before_start_apply_only_the_latest_state_once
    assert @update.pending?
    %w[first second latest].each do |version|
      File.write(File.join(@source, 'guest/configure.py'), version)
      assert @update.pending?
    end
    assert_empty @calls
    sync
    assert_equal [[:configuration, {prepare_host:false, integrations:false}]], configuration_calls
    assert_equal @update.desired['configuration'], @payload['applied']['configuration']
    refute @update.pending?
    @calls.clear
    sync
    assert_equal [:probe], @calls
    File.utime(Time.now, Time.now, File.join(@source, 'guest/configure.py'))
    AgentVM.write(File.join(@source, 'README.md'), 'documentation only')
    refute @update.pending?
  end
  def test_failure_is_not_marked_applied_and_retry_uses_latest_source
    @installer.define_singleton_method(:apply_configuration) { |*_, **_| raise AgentVM::Error, 'interrupted' }
    assert_raises(AgentVM::Error) { sync }
    assert_empty @payload['applied']
    assert @update.pending?
    refute File.exist?(@vm.file('guest-update-state.json'))
  end
  def test_transport_release_change_is_deferred_and_applied_once
    @vm.config['tart_guest_agent_version'] = '1.0.0'
    sync
    @calls.clear
    @vm.config['tart_guest_agent_version'] = '1.1.0'
    assert @update.pending?
    assert_empty @calls, 'Checking pending transport changes must not contact the guest'
    sync
    assert_equal 1, configuration_calls.length
    refute @update.pending?
    @calls.clear
    sync
    assert_equal [:probe], @calls
  end
  def test_deleted_helper_is_repaired_without_reapplying_configuration
    sync
    @calls.clear
    @payload['helpers']['command'] = nil
    sync
    assert_includes @calls, :helpers
    assert_empty configuration_calls
  end
  def test_optional_camera_refresh_does_not_install_or_enable_a_new_module
    sync
    refute_includes @calls, :camera
    @payload['camera_installed'] = true
    @calls.clear
    sync
    assert_includes @calls, :camera
    refute @vm.config['camera_obs']
    refute @update.pending?
    @calls.clear
    File.write(File.join(@source, 'guest/camera-receiver.rb'), 'new receiver')
    assert @update.pending?
    sync
    assert_empty configuration_calls
    assert_includes @calls, :camera
  end
  def test_guest_rollback_overrides_host_cache_and_replaced_disk_invalidates_cache
    sync
    @payload['applied'] = {}
    @calls.clear
    sync
    assert_equal 1, configuration_calls.length
    File.rename(File.join(@tmp, 'disk.img'), File.join(@tmp, 'old.img'))
    AgentVM.write(File.join(@tmp, 'disk.img'), 'restored disk')
    assert @update.pending?
  end
  def test_retained_throwaways_never_probe_or_apply_later_updates
    @vm.config['throwaway'] = {'id'=>'abcdef01'}
    sync
    assert_empty @calls
    refute File.exist?(@vm.file('guest-update-state.json'))
  end
end
