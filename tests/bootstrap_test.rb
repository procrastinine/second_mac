require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/core'

class BootstrapTest < Minitest::Test
  def test_minimum_host_version_accepts_tahoe_without_accepting_older_or_malformed_versions
    script = File.expand_path('../bootstrap.sh', __dir__)
    %w[26.0 26.7.1 27.0 28.0].each do |version|
      _, error, status = Open3.capture3('/bin/bash', '-c', 'source "$1"; bootstrap_supported_host "$2"', 'host-check', script, version)
      assert status.success?, error
    end
    ['', '15.7', '25.9', 'invalid', '27; false'].each do |version|
      _, _, status = Open3.capture3('/bin/bash', '-c', 'source "$1"; bootstrap_supported_host "$2"', 'host-check', script, version)
      refute status.success?
    end
  end

  def setup
    @directory = File.realpath(Dir.mktmpdir('agent-vm-bootstrap-'))
    @script = File.expand_path('../bootstrap.sh', __dir__)
    @checkout = File.join(@directory, 'checkout with spaces')
  end
  def teardown
    FileUtils.remove_entry(@directory)
  end
  def git(*args)
    AgentVM.run('/usr/bin/git', *args, capture:true)
  end
  def test_downloaded_entrypoint_accepts_modular_options_without_writes_in_plan
    output = AgentVM.run('/bin/bash', '-s', '--', '--repo', 'example/agent-vm', '--plan', '--checkout', @checkout,
      '--agents', 'pi,codex', '--profiles', 'web,science', input:File.read(@script), capture:true)
    assert_includes output, 'Installer options:'
    assert_includes output, 'pi\\,codex'
    refute File.exist?(@checkout)
  end
  def test_default_repository_plan_requires_no_private_configuration
    output = AgentVM.run('/bin/bash', '-s', '--', '--plan', '--checkout', @checkout,
      input:File.read(@script), capture:true)
    assert_includes output, 'https://github.com/procrastinine/second_mac.git'
    refute File.exist?(@checkout)
  end
  def test_real_git_clone_repeat_update_and_dirty_checkout_protection
    origin = File.join(@directory, 'origin')
    git('init', '-b', 'main', origin)
    git('-C', origin, 'config', 'user.name', 'Bootstrap test')
    git('-C', origin, 'config', 'user.email', 'test@example.invalid')
    FileUtils.mkdir_p(File.join(origin, 'lib'))
    File.write(File.join(origin, 'lib/install-cli.rb'), '# fixture')
    File.write(File.join(origin, 'install.sh'), "#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
    git('-C', origin, 'add', '.')
    git('-C', origin, 'commit', '-m', 'fixture')
    runner = File.join(@directory, 'run.sh')
    File.write(runner, <<~BASH)
      source #{Shellwords.escape(@script)}
      bootstrap_dependencies() { :; }
      bootstrap_git() { /usr/bin/git -c #{Shellwords.escape('url.file://' + origin + '.insteadOf=https://github.com/example/agent-vm.git')} "$@"; }
      bootstrap_main "$@"
    BASH
    args = ['/bin/bash', runner, '--repo', 'example/agent-vm', '--checkout', @checkout,
            '--name', 'sample-box', '--profiles', 'web,science', '--agents', 'pi', '--share', '/tmp/shared files']
    output = AgentVM.run(*args, capture:true)
    assert_equal ["--name\n", "sample-box\n", "--profiles\n", "web,science\n", "--agents\n", "pi\n", "--share\n", "/tmp/shared files\n"], output.lines
    File.write(File.join(origin, 'current-version'), 'updated')
    git('-C', origin, 'add', '.')
    git('-C', origin, 'commit', '-m', 'current upstream')
    AgentVM.run(*args, capture:true)
    assert_equal 'updated', File.read(File.join(@checkout, 'current-version'))
    File.write(File.join(@checkout, 'local-change'), 'retain this')
    error = assert_raises(AgentVM::Error) { AgentVM.run(*args, capture:true) }
    assert_includes error.message, 'local changes'
    assert_equal 'retain this', File.read(File.join(@checkout, 'local-change'))
  end

  def test_interrupted_clone_can_be_retried_without_cleaning_the_destination
    origin = File.join(@directory, 'retry-origin')
    git('init', '-b', 'main', origin)
    git('-C', origin, 'config', 'user.name', 'Bootstrap test')
    git('-C', origin, 'config', 'user.email', 'test@example.invalid')
    FileUtils.mkdir_p(File.join(origin, 'lib'))
    File.write(File.join(origin, 'lib/install-cli.rb'), '# fixture')
    File.write(File.join(origin, 'install.sh'), "#!/bin/sh\nprintf 'RESUMED\\n'\n")
    git('-C', origin, 'add', '.')
    git('-C', origin, 'commit', '-m', 'fixture')
    failed = File.join(@directory, 'interrupted-once')
    runner = File.join(@directory, 'retry.sh')
    File.write(runner, <<~BASH)
      source #{Shellwords.escape(@script)}
      bootstrap_dependencies() { :; }
      bootstrap_git() {
        if [[ "$1" == clone && ! -e #{Shellwords.escape(failed)} ]]; then
          touch #{Shellwords.escape(failed)}
          mkdir -p "${@: -1}/.git"
          return 23
        fi
        /usr/bin/git -c #{Shellwords.escape('url.file://' + origin + '.insteadOf=https://github.com/example/retry.git')} "$@"
      }
      bootstrap_main "$@"
    BASH
    args = ['/bin/bash', runner, '--repo', 'example/retry', '--checkout', @checkout]
    assert_raises(AgentVM::Error) { AgentVM.run(*args, capture:true) }
    refute File.exist?(@checkout)
    assert_empty Dir.glob(@checkout + '.partial.*')
    assert_equal "RESUMED\n", AgentVM.run(*args, capture:true)
    assert File.file?(File.join(@checkout, 'install.sh'))
  end
end
