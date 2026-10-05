require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/install'

class HostPathTest < Minitest::Test
  def setup
    @environment = ENV.to_h
    @tmp = File.realpath(Dir.mktmpdir('second-mac-path-'))
    ENV['HOME'] = File.join(@tmp, "home space ' quote")
    ENV['AGENT_VM_HOME'] = File.join(@tmp, 'private state')
    ENV['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin'
    ENV['SHELL'] = '/bin/zsh'
    %w[ZDOTDIR XDG_CONFIG_HOME BASH_ENV ENV].each { |key| ENV.delete(key) }
    @vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('name'=>'test-box', 'user'=>'builder'))
    @installer = AgentVM::Installer.new(@vm.config)
    @brew = File.join(@tmp, 'homebrew/bin/brew')
    AgentVM.write(@vm.file('runtime/lib/cli.rb'), 'puts ENV.fetch("PATH").split(File::PATH_SEPARATOR).count { |entry| entry == File.join(Dir.home, ".local/bin") }' + "\n")
  end

  def teardown
    ENV.replace(@environment)
    FileUtils.remove_entry(@tmp)
  end

  def install
    AgentVM::HostPath.stub(:homebrew_executable, @brew) do
      capture_io { @installer.integrations(@vm) }
    end
  end

  def assert_shell_finds_command(shell, flag)
    output, error, status = Open3.capture3(shell, flag, 'command -v vm; vm')
    assert status.success?, error
    assert_equal [File.join(Dir.home, '.local/bin/vm'), '1'], output.lines.map(&:strip)
  end

  def test_already_on_path_leaves_startup_files_untouched
    rc = File.join(Dir.home, '.zshrc')
    AgentVM.write(rc, "# existing settings\n", 0644)
    FileUtils.mkdir_p(File.join(Dir.home, '.local/bin'))
    alias_path = File.join(@tmp, 'bin alias')
    File.symlink(File.join(Dir.home, '.local/bin'), alias_path)
    ENV['PATH'] = alias_path + '/:' + ENV['PATH']
    install
    assert_equal "# existing settings\n", File.read(rc)
    refute File.exist?(@vm.file('shell-config-backups'))
  end

  def test_zsh_new_terminal_finds_vm_and_preserves_symlinked_configuration
    ENV['ZDOTDIR'] = File.join(Dir.home, '.config/zsh')
    target = File.join(Dir.home, 'dotfiles/zshrc')
    original = '# existing settings without final newline'
    AgentVM.write(target, original, 0644)
    FileUtils.mkdir_p(ENV['ZDOTDIR'])
    rc = File.join(ENV['ZDOTDIR'], '.zshrc')
    File.symlink(target, rc)
    install
    before = File.binread(target)
    install
    assert_equal before, File.binread(target)
    assert File.symlink?(rc)
    assert_equal 0644, File.stat(target).mode & 0777
    backups = Dir.glob(@vm.file('shell-config-backups/*'))
    assert_equal 1, backups.length
    assert_equal original, File.binread(backups.first)
    assert_equal 0600, File.stat(backups.first).mode & 0777
    assert_shell_finds_command('/bin/zsh', '-ic')
    assert_shell_finds_command('/bin/zsh', '-lic')
  end

  def test_bash_preserves_existing_login_profile_and_handles_nonlogin_shells
    ENV['SHELL'] = '/bin/bash'
    profile = File.join(Dir.home, '.bash_login')
    AgentVM.write(profile, "export EXISTING_SETTING=preserved\n")
    install
    install
    refute File.exist?(File.join(Dir.home, '.bash_profile'))
    assert File.read(profile).start_with?("export EXISTING_SETTING=preserved\n")
    assert_shell_finds_command('/bin/bash', '-ic')
    assert_shell_finds_command('/bin/bash', '-lic')
  end

  def test_opt_out_writes_neither_commands_nor_shell_settings
    @installer = AgentVM::Installer.new(@vm.config, integrations:false)
    install
    refute File.exist?(File.join(Dir.home, '.local/bin/vm'))
    refute File.exist?(File.join(Dir.home, '.zshrc'))
    refute File.exist?(File.join(Dir.home, '.ssh'))
  end

  def test_homebrew_shellenv_is_loaded_before_existing_zsh_configuration
    prefix = File.dirname(File.dirname(@brew))
    FileUtils.mkdir_p(File.join(prefix, 'sbin'))
    environment = "export HOMEBREW_PREFIX=#{Shellwords.escape(prefix)}\nexport PATH=#{Shellwords.escape(prefix)}/bin:$PATH\n"
    AgentVM.write(@brew, "#!/bin/sh\n#{Shellwords.join(['/usr/bin/printf', '%s', environment])}\n", 0755)
    rc = File.join(Dir.home, '.zshrc')
    AgentVM.write(rc, "export EXISTING_STARTUP_PREFIX=\"$HOMEBREW_PREFIX\"\n")
    install
    original = File.binread(rc)
    install
    assert_equal original, File.binread(rc)
    output, error, status = Open3.capture3('/bin/zsh', '-ic', 'printf "%s\\n" "$EXISTING_STARTUP_PREFIX"; command -v brew; command -v vm')
    assert status.success?, error
    assert_equal [prefix, @brew, File.join(Dir.home, '.local/bin/vm')], output.lines.map(&:strip)
    refute_match(/compinit|autoload/, File.read(rc))
  end

  def test_unknown_shell_retains_installed_command_and_gives_clear_fallback
    ENV['SHELL'] = '/usr/local/bin/custom-shell'
    output, error = install
    assert_match(/needs manual PATH setup/, error)
    assert_empty output
    assert File.executable?(File.join(Dir.home, '.local/bin/vm'))
    refute File.exist?(File.join(Dir.home, '.zshrc'))
  end
end
