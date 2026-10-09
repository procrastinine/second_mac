require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/permissions'
require_relative '../guest/install-control'

class PermissionClientTest < Minitest::Test
  def test_retained_throwaway_keeps_its_saved_client_without_guest_contact
    vm = Object.new
    vm.define_singleton_method(:config) { {'phase'=>'ready', 'throwaway'=>{'id'=>'abcdef01'}} }
    vm.define_singleton_method(:root) { |*| raise 'Replaced throwaway helper' }
    vm.define_singleton_method(:ssh) { |*| raise 'Contacted throwaway to migrate it' }
    assert_nil AgentVM::Permissions.new(vm).install_client
  end
  def test_launchd_ascii_locale_can_serialize_utf8_helper_sources
    previous = Encoding.default_external
    Encoding.default_external = Encoding::US_ASCII
    value = nil
    vm = Object.new
    vm.define_singleton_method(:config) { {'phase'=>'ready', 'user'=>'builder'} }
    vm.define_singleton_method(:ui_available?) { false }
    vm.define_singleton_method(:root) { |*_, **options| value = JSON.parse(options.fetch(:input)) }
    AgentVM::Permissions.new(vm).install_client
    assert value.fetch('sources').values.all?(&:valid_encoding?)
    assert_includes value['sources']['control-client.rb'], 'mac-control password'
  ensure
    Encoding.default_external = previous
  end
  def test_existing_guest_receives_helpers_and_display_fix_once_without_package_installers
    calls = []
    display = 10
    directory = Dir.mktmpdir('mac-control-install-')
    account = Struct.new(:dir, :uid, :gid).new(File.join(directory, 'home'), Process.uid, Process.gid)
    root = File.join(directory, 'libexec')
    vm = Object.new
    vm.define_singleton_method(:config) { {'phase'=>'ready', 'user'=>'developer', 'ui_enabled'=>true} }
    vm.define_singleton_method(:ui_available?) { true }
    vm.define_singleton_method(:home) { account.dir }
    vm.define_singleton_method(:ssh) do |*args, **_options|
      calls << args
      case args[0]
      when '/usr/bin/pmset' then "displaysleep #{display}\n"
      else raise 'Unexpected guest command'
      end
    end
    vm.define_singleton_method(:root) do |*args, **options|
      calls << args
      case args[0]
      when '/usr/bin/pmset' then display = 0
      when '/usr/bin/ruby'
        GuestControlInstall.install(account, JSON.parse(options.fetch(:input)).fetch('sources'), root:root)
      else raise 'Unexpected guest mutation'
      end
    end
    helper = AgentVM::Permissions.new(vm)
    helper.install_client
    assert_equal 0, display
    files = Dir.glob(File.join(directory, '**', '*'), File::FNM_DOTMATCH).select { |path| File.file?(path) }
    assert_equal GuestControlInstall::SOURCES.length + 1, files.length
    assert File.file?(File.join(root, 'skills/mac-control/SKILL.md'))
    executable = File.join(account.dir, '.local/bin/mac-control')
    assert_equal File.read(File.expand_path('../guest/control-client.rb', __dir__)), File.read(executable)
    assert_equal File.read(executable), File.read(File.join(root, 'control-client.rb'))
    refute File.exist?(File.join(account.dir, '.local/bin/vm'))
    refute File.exist?(File.join(account.dir, '.local/bin/vm-control'))
    before = files.map { |path| File.stat(path).ino }
    calls.clear
    helper.install_client
    assert_equal %w[/usr/bin/pmset /usr/bin/ruby], calls.map(&:first)
    assert_equal before, files.map { |path| File.stat(path).ino }
  ensure
    FileUtils.remove_entry(directory) if directory
  end
  def test_rename_removes_only_recognized_legacy_scripts_and_preserves_other_commands
    Dir.mktmpdir('mac-control-migrate-') do |directory|
      account = Struct.new(:dir, :uid, :gid).new(directory, Process.uid, Process.gid)
      bin = File.join(directory, '.local/bin')
      FileUtils.mkdir_p(bin)
      old = "#!/bin/sh\nexit 0\n"
      %w[vm vm-control].each { |name| File.write(File.join(bin, name), old) }
      known = %w[vm vm-control].to_h { |name| [name, [Digest::SHA256.hexdigest(old)]] }
      GuestControlInstall.stub(:legacy_digests, known) do
        sources = {'control-client.rb'=>'new helper'}
        root = File.join(directory, 'libexec')
        GuestControlInstall.install(account, sources, root:root)
        %w[vm vm-control].each { |name| refute File.exist?(File.join(bin, name)) }
        File.write(File.join(bin, 'vm'), '# unrelated user command')
        File.symlink('vm', File.join(bin, 'vm-control'))
        GuestControlInstall.install(account, sources, root:root)
        assert_equal '# unrelated user command', File.read(File.join(bin, 'vm'))
        assert File.symlink?(File.join(bin, 'vm-control'))
      end
    end
  end
  def test_watcher_retries_a_transient_launchd_restart_failure
    Dir.mktmpdir('second-mac-watch-') do |directory|
      vm = Object.new
      vm.define_singleton_method(:config) { {'permissions_auto'=>true, 'ui_enabled'=>true} }
      vm.define_singleton_method(:ui_available?) { true }
      vm.define_singleton_method(:running?) { true }
      vm.define_singleton_method(:running_pid) { 123 }
      vm.define_singleton_method(:name) { 'test-box' }
      vm.define_singleton_method(:domain) { 'gui/999999' }
      vm.define_singleton_method(:file) { |name| File.join(directory, name) }
      permissions = AgentVM::Permissions.new(vm)
      count = 0
      permissions.stub(:stop_watcher, nil) do
        permissions.stub(:sleep, nil) do
          AgentVM.stub(:run, lambda { |*_, **_options| count += 1; raise AgentVM::Error, 'Bootstrap failed: 5' if count == 1 }) do
            permissions.start_watcher
          end
        end
      end
      assert_equal 2, count
    end
  end
end
