require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/network-build'

class NetworkBuildTest < Minitest::Test
  def setup
    @environment = ENV.to_h
    @temporary = Dir.mktmpdir('network-build-')
    ENV['AGENT_VM_HOME'] = @temporary
    @vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('name'=>'network-box'))
    @vm.define_singleton_method(:exclude_backup) { |*| }
    @builder = AgentVM::NetworkBuild.new(@vm)
    @calls, @resolved, @latest, @fail = [], {}, 'v1.2.3', false
  end
  def teardown
    ENV.replace(@environment)
    FileUtils.remove_entry(@temporary)
  end
  def run_build(*args, **_options)
    @calls << args
    source = args.include?('-C') ? args[args.index('-C') + 1] : nil
    if args.include?('get')
      @resolved[source] = args.last.split('@').last
    elsif args.include?('list')
      return JSON.generate('Version'=>args.last.end_with?('@latest') ? @latest : @resolved.fetch(source))
    elsif args.include?('init')
      File.write(File.join(source, 'go.mod'), 'module test')
    elsif args.include?('build')
      raise AgentVM::Error, 'Compiler interrupted' if @fail
      AgentVM.write(args[args.index('-o') + 1], 'helper:' + @resolved.fetch(source), 0700)
    end
    ''
  end
  def building
    AgentVM.stub(:run, method(:run_build)) { capture_io { yield } }
  end
  def test_first_build_resolves_latest_but_normal_starts_never_query_or_compile_again
    binary = nil
    building { binary = @builder.install }
    assert_equal @latest, @vm.config['network_library_version']
    assert_equal 'helper:' + @latest, File.read(binary)
    assert @calls.any? { |args| args.include?('get') && args.last.end_with?('@' + @latest) }
    AgentVM.stub(:run, ->(*) { flunk 'Cached startup must not check for updates or compile' }) do
      assert_equal binary, AgentVM::NetworkBuild.new(@vm).install
    end
  end
  def test_explicit_update_keeps_prior_binary_and_retained_copy_version
    original = nil
    building { original = @builder.install }
    previous = @vm.config.dup
    @latest = 'v1.3.0'
    building { @builder.update }
    assert_equal @latest, @vm.config['network_library_version']
    assert_equal 'v1.2.3', JSON.parse(File.read(@vm.file('config.json')))['network_library_version'],
      'The combined updater must commit dependency selections only after every required build succeeds'
    assert_equal 'helper:v1.2.3', File.read(original)
    refute_equal original, @builder.install
    copy = AgentVM::VM.new(previous.merge('name'=>'retained-box'))
    AgentVM.stub(:run, ->(*) { flunk 'Retained copy must keep its original networking build' }) do
      assert_equal original, AgentVM::NetworkBuild.new(copy).install
    end
  end
  def test_failed_upgrade_leaves_last_working_version_selected_and_retry_succeeds
    original = nil
    building { original = @builder.install }
    @latest, @fail = 'v1.3.0', true
    building { assert_raises(AgentVM::Error) { @builder.update } }
    assert_equal 'v1.2.3', @vm.config['network_library_version']
    assert_equal 'helper:v1.2.3', File.read(original)
    @fail = false
    building { @builder.update }
    assert_equal @latest, @vm.config['network_library_version']
  end
  def test_recipe_changes_rebuild_same_dependency_without_implicit_upgrade
    original = nil
    building { original = @builder.install }
    @latest = 'v9.0.0'
    changed = AgentVM::NetworkBuild.new(@vm)
    changed.define_singleton_method(:source_digest) { 'changed-source' }
    @calls.clear
    binary = nil
    building { binary = changed.install }
    refute_equal original, binary
    assert_equal 'helper:v1.2.3', File.read(binary)
    refute @calls.any? { |args| args.last.end_with?('@latest') }
  end
  def test_migration_keeps_legacy_library_and_rejects_changed_binary
    directory = File.join(@builder.root, 'legacy-cache')
    binary = File.join(directory, 'bin/softnet')
    AgentVM.write(binary, 'legacy binary', 0700)
    AgentVM.json_write(File.join(directory, 'manifest.json'), {'network_library'=>'v1.0.0', 'binary_sha256'=>Digest::SHA256.file(binary).hexdigest})
    AgentVM.json_write(@vm.file('network-state.json'), {'backend'=>'vpn', 'binary'=>binary})
    assert_equal 'v1.0.0', @builder.current_version
    building { @builder.install }
    assert_equal 'v1.0.0', @vm.config['network_library_version']
    refute @calls.any? { |args| args.last.end_with?('@latest') }
    @vm.config.delete('network_library_version')
    File.write(binary, 'changed binary')
    assert_nil @builder.current_version
  end
  def test_native_only_updates_never_install_go_or_contact_module_proxy
    AgentVM.stub(:run, ->(*) { flunk 'Unused VPN helper must remain optional' }) do
      assert_nil @builder.update
      assert_nil @builder.check
    end
    refute File.exist?(@builder.root)
    assert_raises(AgentVM::Error) { @builder.install('../../invalid') }
  end
end
