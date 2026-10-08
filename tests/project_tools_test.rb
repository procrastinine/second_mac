require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require_relative '../lib/project-tool'
require_relative '../lib/project-tools-setup'
require_relative '../lib/projects'

class ProjectToolsTest < Minitest::Test
  def setup
    @tmp = File.realpath(Dir.mktmpdir('project-tools-test-'))
    @home = File.join(@tmp, 'home')
    @root = File.join(@tmp, 'project with spaces')
    @outside = File.join(@tmp, 'outside')
    @native = File.join(@tmp, 'native')
    [@home, @root, @outside, @native].each { |dir| FileUtils.mkdir_p(dir) }
    @old_shell, @old_zdotdir = ENV['SHELL'], ENV['ZDOTDIR']
    ENV['SHELL'] = '/bin/zsh'
    ENV.delete('ZDOTDIR')
    @request = {'action'=>'setup', 'root'=>@root,
      'entry'=>{'id'=>'example', 'tools'=>%w[pnpm uv], 'store'=>File.join(@tmp, 'store'), 'uv_cache'=>File.join(@tmp, 'cache'), 'python_dir'=>File.join(@tmp, 'python')},
      'adapter'=>File.read(File.expand_path('../lib/project-tool.rb', __dir__)),
      'fsync_source'=>File.read(File.expand_path('../lib/fsync-compat.c', __dir__))}
    @result = ProjectToolsSetup.configure(@request, @home)
    @bin = @result.fetch('bin')
    script = <<~'RUBY'
      #!/usr/bin/ruby
      require 'json'
      puts JSON.generate('args'=>ARGV, 'cwd'=>Dir.pwd,
        'version'=>File.read(File.join(__dir__, 'version')),
        'store'=>ENV['PNPM_CONFIG_STORE_DIR'],
        'verify'=>ENV['PNPM_CONFIG_VERIFY_DEPS_BEFORE_RUN'],
        'global_store'=>ENV['PNPM_CONFIG_ENABLE_GLOBAL_VIRTUAL_STORE'],
        'environment'=>ENV['UV_PROJECT_ENVIRONMENT'],
        'cache'=>ENV['UV_CACHE_DIR'], 'python'=>ENV['UV_PYTHON_INSTALL_DIR'])
    RUBY
    %w[pnpm uv].each { |tool| File.write(File.join(@native, tool), script); File.chmod(0755, File.join(@native, tool)) }
    File.write(File.join(@native, 'version'), 'first')
  end
  def teardown
    ENV['SHELL'], ENV['ZDOTDIR'] = @old_shell, @old_zdotdir
    FileUtils.remove_entry(@tmp)
  end
  def run_tool(tool, *args, cwd:@root)
    env = {'HOME'=>@home, 'PATH'=>[@bin, @native, '/usr/bin', '/bin'].join(':')}
    %w[PNPM_CONFIG_STORE_DIR PNPM_CONFIG_VERIFY_DEPS_BEFORE_RUN PNPM_CONFIG_ENABLE_GLOBAL_VIRTUAL_STORE UV_PROJECT_ENVIRONMENT UV_CACHE_DIR UV_PYTHON_INSTALL_DIR].each { |key| env[key] = nil }
    output, error, status = Open3.capture3(env, File.join(@bin, tool), *args, chdir:cwd)
    assert status.success?, error
    JSON.parse(output)
  end
  def test_setup_changes_no_project_files_and_is_idempotent
    assert_empty Dir.children(@root)
    first = File.read(File.join(@home, '.zshrc'))
    assert_equal @result, ProjectToolsSetup.configure(@request, @home)
    assert_equal first, File.read(File.join(@home, '.zshrc'))
    assert_equal 1, first.scan('# >>> project tools >>>').length
    assert File.file?(File.join(@home, '.zshenv'))
    assert_equal 0600, File.stat(File.join(@home, '.config/project-tools/projects.json')).mode & 0777
  end
  def test_pnpm_uses_native_checks_and_global_commands_are_unmodified
    settings = run_tool('pnpm', 'dev')
    assert_equal 'error', settings['verify']
    assert_equal 'false', settings['global_store']
    assert_equal @request['entry']['store'], settings['store']
    %w[self-update setup].each { |cmd| assert_nil run_tool('pnpm', cmd)['store'] }
    assert_nil run_tool('pnpm', 'install', '-g', 'example')['verify']
    assert_nil run_tool('pnpm', '--version', cwd:@outside)['store']
    assert_equal 'error', run_tool('pnpm', 'run', 'dev', 'self-update', '--global')['verify']
  end
  def test_directory_flags_are_supported_without_reinterpreting_script_arguments
    assert_equal 'error', run_tool('pnpm', '-C', @root, 'run', 'dev', cwd:@outside)['verify']
    assert_nil run_tool('pnpm', '-C', @outside, 'run', 'dev')['verify']
    assert_equal 'error', run_tool('pnpm', 'run', 'dev', '--dir', @outside)['verify']
    expected = File.join(@home, '.local/share/project-tools/environments/example')
    assert_equal expected, run_tool('uv', '--project', @root, 'run', 'python', cwd:@outside)['environment']
    assert_equal expected, run_tool('uv', '--directory=' + @root, 'sync', cwd:@outside)['environment']
    assert_nil run_tool('uv', 'sync', cwd:@outside)['environment']
  end
  def test_tool_updates_are_discovered_without_reconfiguring
    assert_equal 'first', run_tool('pnpm', '--version')['version']
    File.write(File.join(@native, 'version'), 'updated')
    assert_equal 'updated', run_tool('pnpm', '--version')['version']
    shim = File.join(@tmp, 'shim')
    File.write(shim, "#!/bin/sh\n# cmd-shim-target=#{File.join(@native, 'pnpm')}\n")
    assert_equal File.join(@native, 'pnpm'), ProjectTool.direct_binary(shim)
    File.write(shim, "#!/bin/sh\n# cmd-shim-target=#{File.join(@native, 'uv')}\n")
    assert_equal File.join(@native, 'uv'), ProjectTool.direct_binary(shim)
  end
  def test_nested_projects_do_not_inherit_parent_tool_configuration
    child = File.join(@root, 'child')
    FileUtils.mkdir_p(child)
    request = @request.merge('root'=>child, 'entry'=>@request['entry'].merge('tools'=>['npm'], 'id'=>'child'))
    ProjectToolsSetup.configure(request, @home)
    assert_nil run_tool('pnpm', 'run', 'dev', cwd:child)['store']
    assert_nil run_tool('uv', 'run', 'python', cwd:child)['environment']
  end
  def test_remove_retains_project_files_and_environments
    File.write(File.join(@root, 'user-file'), 'keep')
    ProjectToolsSetup.configure(@request.merge('action'=>'remove'), @home)
    assert_equal 'keep', File.read(File.join(@root, 'user-file'))
    assert_nil run_tool('pnpm', 'dev')['verify']
  end
  def test_uv_shares_downloads_and_retains_an_existing_working_environment
    existing = File.join(@root, '.venv')
    FileUtils.mkdir_p(File.join(existing, 'bin'))
    python = File.join(existing, 'bin/python')
    File.write(python, "#!/bin/sh\nexit 0\n")
    File.chmod(0755, python)
    marker = File.join(existing, 'existing-package')
    File.write(marker, 'preserve')
    request = @request.merge('entry'=>@request['entry'].merge('reuse_existing'=>true))
    result = ProjectToolsSetup.configure(request, @home)
    assert result['reused_environment']
    assert_equal existing, result['environment']
    assert_equal 'preserve', File.read(marker)
    settings = run_tool('uv', 'sync')
    assert_equal existing, settings['environment']
    assert_equal @request['entry']['uv_cache'], settings['cache']
    assert_equal @request['entry']['python_dir'], settings['python']
    File.unlink(python)
    File.symlink('/nonexistent/interpreter', python)
    result = ProjectToolsSetup.configure(request, @home)
    refute result['reused_environment']
    refute_equal existing, result['environment']
    assert_equal 'preserve', File.read(marker)
  end
  def test_native_flush_preserves_fcntl_arguments_errors_and_child_environment
    library = File.join(@tmp, 'flush.dylib')
    binary = File.join(@tmp, 'flush-probe')
    source = File.expand_path('../lib/fsync-compat.c', __dir__)
    probe = File.join(__dir__, 'project_fsync_probe.c')
    [[source, '-dynamiclib', '-o', library], [probe, '-o', binary]].each do |args|
      output, status = Open3.capture2e('/usr/bin/clang', '-Wall', '-Wextra', '-Werror', *args)
      assert status.success?, output
    end
    output, status = Open3.capture2e({'DYLD_INSERT_LIBRARIES'=>library}, binary, File.join(@tmp, 'flush-probe-data'))
    assert status.success?, output
    result = JSON.parse(output)
    assert_equal 0, result['flush']
    assert result['forwarding']
    assert result['bad_fd_preserved']
    assert result['child_environment_clean']
  end
  def test_transitive_presence_versions_and_explicit_platform_skips
    package = File.join(@root, 'node_modules/child')
    FileUtils.mkdir_p(package)
    manifest = File.join(package, 'package.json')
    File.write(manifest, JSON.generate('name'=>'child', 'version'=>'1.0.0'))
    child = {'from'=>'child', 'version'=>'1.0.0', 'path'=>package}
    tree = [{'dependencies'=>{'parent'=>{'dependencies'=>{'child'=>child}}}}]
    groups = %w[dependencies devDependencies optionalDependencies]
    ProjectTool.check_packages(tree, Set.new, groups)
    File.write(manifest, JSON.generate('name'=>'child', 'version'=>'2.0.0'))
    error = assert_raises(RuntimeError) { ProjectTool.check_packages(tree, Set.new, groups) }
    assert_includes error.message, 'version "2.0.0"'
    File.unlink(manifest)
    error = assert_raises(RuntimeError) { ProjectTool.check_packages(tree, Set.new, groups) }
    assert_includes error.message, 'pnpm install --frozen-lockfile'
    ProjectTool.check_packages(tree, Set.new(['child@1.0.0']), groups)
    assert ProjectTool.runs_code?(%w[-C somewhere run dev], @root)
    refute ProjectTool.runs_code?(%w[install --frozen-lockfile], @root)
    refute ProjectTool.runs_code?(%w[self-update], @root)
  end
  def test_guest_payload_is_neutral_and_has_no_project_specific_switches
    [@request['adapter'], @request['fsync_source'],
     File.read(File.expand_path('../lib/project-tools-setup.rb', __dir__))].each do |source|
      refute_match(/maclauncher|agent.vm|\bguest\b|\bVM\b/i, source)
    end
  end
  def test_share_mapping_rejects_readonly_outside_and_escaping_paths
    config = AgentVM::DEFAULTS.merge('sharing'=>'native', 'share'=>@root, 'guest_share'=>'work', 'user'=>'developer')
    fake = Struct.new(:config).new(config)
    handler = AgentVM::Projects.new(fake)
    assert_equal [@root, '/Users/developer/work/'], handler.mapping(@root)
    assert_raises(AgentVM::Error) { handler.mapping(@outside) }
    File.symlink(@outside, File.join(@root, 'escape'))
    assert_raises(AgentVM::Error) { handler.mapping(File.join(@root, 'escape')) }
    config['share_read_only'] = true
    assert_raises(AgentVM::Error) { handler.mapping(@root) }
  end
end
