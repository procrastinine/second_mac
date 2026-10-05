require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/profile-plan'
require_relative '../lib/core'
require_relative '../lib/shared'
require_relative '../lib/profiles'

class ProfilesTest < Minitest::Test
  def test_new_and_legacy_installations_have_different_safe_defaults
    fresh = AgentVM.validate(AgentVM::DEFAULTS.dup)
    assert_equal ['base'], fresh['profiles']
    assert_empty fresh['agents']
    assert_equal 'hybrid', fresh['sharing']
    old = AgentVM::DEFAULTS.reject { |key, _| %w[profiles desktop_on_demand sharing].include?(key) }
    assert_equal AgentVM::ProfilePlan::LEGACY, AgentVM.validate(old)['profiles']
    assert_equal 'macfuse', old['sharing']
    assert_raises(AgentVM::Error) { AgentVM.validate(fresh.merge('agents'=>'pi')) }
    assert_raises(AgentVM::Error) { AgentVM.validate(fresh.merge('profiles'=>['invalid'])) }
  end
  def test_optional_agents_add_browser_tools_without_unrelated_profiles
    assert_equal %w[base web], AgentVM::ProfilePlan.expand(['base'], ['pi'])
    assert_equal %w[base science], AgentVM::ProfilePlan.expand(['science'])
  end
  def test_plans_do_not_leak_heavy_tools_into_base
    Dir.mktmpdir do |directory|
      packages = File.expand_path('../packages', __dir__)
      plan = AgentVM::ProfilePlan.generate({'profiles'=>['base']}, packages, directory)
      assert_equal ['base'], plan
      brew = File.read(File.join(directory, 'Brewfile'))
      assert_includes brew, '"tmux"'
      assert_includes brew, '"sevenzip"'
      refute_match(/brave|ffmpeg|libreoffice|openjdk|rustup/, brew)
      refute_match(/torch|numpy|playwright/, File.read(File.join(directory, 'python.txt')))
      assert_empty File.read(File.join(directory, 'npm.txt')).strip
      AgentVM::ProfilePlan.generate({'profiles'=>['full']}, packages, directory)
      assert_includes File.read(File.join(directory, 'python.txt')), 'torch'
      assert_includes File.read(File.join(directory, 'Brewfile')), 'brave-browser'
      assert_includes File.read(File.join(directory, 'Brewfile')), 'mactex-no-gui'
      assert_equal 1, File.read(File.join(directory, 'Brewfile')).scan('brew "imagemagick"').length
      AgentVM::ProfilePlan.generate({'profiles'=>['media']}, packages, directory)
      assert_includes File.read(File.join(directory, 'Brewfile')), 'imagemagick'
      assert_includes File.read(File.join(directory, 'python.txt')), 'pillow'
      refute_includes File.read(File.join(directory, 'Brewfile')), 'mactex-no-gui'
    end
  end
  def test_native_mode_has_one_literal_read_only_share_and_needs_no_fuse
    Dir.mktmpdir do |directory|
      vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('share'=>directory, 'sharing'=>'native', 'share_read_only'=>true, 'tart'=>'/fake/tart'))
      assert_equal File.realpath(directory), AgentVM::Shared.new(vm).prepare
      shares = vm.run_args.grep(/^--dir=/)
      assert_equal ["--dir=#{directory}:tag=agent-files,ro"], shares
      assert_includes AgentVM.shares(vm.config).first['links'], 'not exported or redacted'
      guest = AgentVM.guest_config(vm.config)
      refute_includes JSON.generate(guest), directory
    end
  end
  def test_install_fills_existing_profile_and_adds_latex_without_reinstalling_agents
    directory = Dir.mktmpdir('profile-inventory-')
    config = AgentVM.validate(AgentVM::DEFAULTS.merge('profiles'=>['media']))
    calls = []
    fake = Object.new
    fake.define_singleton_method(:config) { config }
    fake.define_singleton_method(:running?) { true }
    fake.define_singleton_method(:with_lifecycle_lock) { |&block| block.call }
    fake.define_singleton_method(:home) { '/Users/developer' }
    fake.define_singleton_method(:file) { |name| File.join(directory, name) }
    fake.define_singleton_method(:save) { calls << [:save] }
    fake.define_singleton_method(:ssh) { |*args, **_options| calls << args; args.first == '/bin/sh' ? 'installed tool inventory' : '' }
    installer = AgentVM::Installer.new(config)
    installer.define_singleton_method(:stage) { |_vm, bootstrap:| calls << [:stage, bootstrap] }
    AgentVM::Installer.stub(:new, installer) do
      capture_io { AgentVM::Profiles.new(fake).command(%w[install media latex]) }
    end
    assert_equal %w[base media latex], config['profiles']
    assert_includes calls, [:stage, false]
    installation = calls.find { |args| args[1].to_s.end_with?('install-tools.sh') }
    assert_equal %w[base media latex], installation.drop(2)
    refute calls.any? { |args| args.include?('install-agents.sh') }
    assert_includes File.read(File.join(directory, 'versions.txt')), 'installed tool inventory'
    assert_includes calls, ['/bin/rm', '-f', '/Users/developer/.local/share/agent-vm/versions.txt']
  ensure
    FileUtils.remove_entry(directory) if directory
  end
end
