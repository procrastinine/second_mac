require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require_relative '../lib/completion'

class CompletionTest < Minitest::Test
  def setup
    @environment = ENV.to_h
    @directory = File.realpath(Dir.mktmpdir('vm-completion-'))
    ENV['AGENT_VM_HOME'] = File.join(@directory, "state space ' quote")
    record('agent-box', 'ports'=>[{'direction'=>'host', 'source'=>8080}, {'direction'=>'guest', 'source'=>3000}])
    record('second-box')
    record('throwaway-aabbccdd', 'throwaway'=>{'id'=>'aabbccdd'})
    File.write(File.join(ENV['AGENT_VM_HOME'], 'default'), "agent-box\n")
    snapshot('agent-box', 'before-upgrade')
    snapshot('second-box', 'other-checkpoint')
  end

  def teardown
    ENV.replace(@environment)
    FileUtils.remove_entry(@directory)
  end

  def record(name, extra = {})
    path = File.join(ENV.fetch('AGENT_VM_HOME'), name)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, 'config.json'), JSON.generate({'name'=>name}.merge(extra)))
  end

  def snapshot(name, label)
    path = File.join(ENV.fetch('AGENT_VM_HOME'), name, 'snapshots', label)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, 'manifest.json'), '{}')
  end

  def complete(*words)
    AgentVM::Completion.complete(words)
  end

  def shell_complete(shell, *words)
    # This calls the real shell adapter. compadd is the zsh editor boundary;
    # replacing only it lets a noninteractive test inspect the actual matches.
    adapter = AgentVM::Completion.shell(shell)
    encoded = Shellwords.join(['vm', *words])
    body = if shell == 'bash'
             adapter + "\nCOMP_WORDS=(#{encoded}); COMP_CWORD=#{words.length}; _vm_complete; printf '%s\\n' \"${COMPREPLY[@]}\"\n"
           else
             "compdef() { :; }\n" + adapter + "\nwords=(#{encoded}); CURRENT=#{words.length + 1}; compadd() { local name=${argv[-1]}; print -rl -- \"${(@P)name}\"; }; _vm_complete\n"
           end
    output, error, status = Open3.capture3('/bin/' + shell, shell == 'bash' ? '--noprofile' : '-f', '-c', body)
    assert status.success?, error
    assert_empty error
    output.lines.map(&:chomp).reject(&:empty?)
  end

  def test_commands_subcommands_options_and_values_in_both_shells
    cases = {
      ['snap']=>['snapshot'],
      %w[snapshot re]=>['restore'],
      ['snapshot', '']=>%w[create delete list restore verify],
      ['update', '--runtime', '']=>%w[auto custom standard],
      ['resources', '--m']=>['--memory'],
      ['shares', 'configure', '--sharing', '']=>%w[hybrid macfuse native none],
      ['profiles', 'add', 'science', 'w']=>['web'],
      ['profiles', 'add', 'web,s']=>['web,science'],
      ['agents', 'add', 'c']=>%w[claude codex],
      ['help', 'snapshot', 'r']=>['restore'],
      ['throwaway', 'network', 'aabbccdd', 'o']=>%w[off on],
      ['auth', 'relay', 'autostart', '']=>%w[off on status]
    }
    %w[bash zsh].each do |shell|
      cases.each { |words, expected| assert_equal expected.sort, shell_complete(shell, *words).sort, [shell, words].inspect }
    end
  end

  def test_readline_assignments_and_colon_paths
    assert_equal ['standard'], shell_complete('bash', 'update', '--runtime=st')
    assert_equal ['standard'], shell_complete('bash', 'update', '--runtime', '=', 'st')
    assert_equal %w[auto custom standard], shell_complete('bash', 'update', '--runtime', '=').sort
    assert_equal ['--runtime=standard'], shell_complete('zsh', 'update', '--runtime=st')
    assert_empty shell_complete('bash', 'cp', ':', '~/')
    assert_empty shell_complete('zsh', 'cp', ':~/')
    assert_equal ['--runtime=standard'], AgentVM::Completion.bash_complete(%w[update --runtime=st], wordbreaks:':')
  end

  def test_local_state_is_scoped_to_the_selected_vm
    assert_equal ['before-upgrade'], complete('snapshot', 'restore', '')
    assert_equal ['other-checkpoint'], complete('--name', 'second-box', 'snapshot', 'delete', '')
    assert_equal %w[agent-box second-box throwaway-aabbccdd], complete('--name', '')
    assert_equal ['aabbccdd'], complete('throwaway', 'ssh', 'a')
    assert_equal ['8080'], complete('ports', 'remove', 'host', '')
    assert_equal ['3000'], complete('ports', 'remove', 'guest', '')
    assert_equal ['aabbccdd'], shell_complete('zsh', 'throwaway', 'delete', 'a')
    assert_equal ['other-checkpoint'], shell_complete('bash', '--name', 'second-box', 'snapshot', 'restore', '')
    assert_empty complete('snapshot', 'create', '')
    assert_empty complete('snapshot', 'restore', 'before-upgrade', '')
  end

  def test_completion_stops_at_remote_commands_scripts_and_option_terminators
    [%w[ssh python --], %w[sudo python --], %w[ssh -- --], %w[codex -- --],
     %w[throwaway ssh aabbccdd python --], %w[throwaway create script.sh --],
     %w[throwaway script.sh --]].each { |words| assert_empty complete(*words), words.inspect }
  end

  def test_paths_with_spaces_and_shell_metacharacters_are_only_data
    work = File.join(@directory, 'host files')
    FileUtils.mkdir_p(File.join(work, 'space directory'))
    File.write(File.join(work, '$(touch PWNED)'), '')
    Dir.chdir(work) do
      %w[bash zsh].each do |shell|
        assert_equal ['space directory/'], shell_complete(shell, 'backup', 'sp')
        assert_equal ['$(touch PWNED)'], shell_complete(shell, 'cp', '$(')
      end
      refute File.exist?('PWNED')
    end
  end

  def test_missing_corrupt_and_symlinked_state_does_not_break_completion
    record('bad-json')
    File.write(File.join(ENV['AGENT_VM_HOME'], 'bad-json/config.json'), '{')
    record('bad-id', 'throwaway'=>{'id'=>12345678})
    File.symlink(File.join(ENV['AGENT_VM_HOME'], 'agent-box'), File.join(ENV['AGENT_VM_HOME'], 'linked-box'))
    assert_equal ['aabbccdd'], complete('throwaway', 'delete', '')
    refute_includes complete('--name', ''), 'linked-box'
    refute_includes complete('--name', ''), 'bad-json'
    ENV['AGENT_VM_HOME'] = File.join(@directory, 'missing')
    assert_equal ['snapshot'], complete('snap')
    assert_empty complete('snapshot', 'restore', '')
    refute File.exist?(ENV['AGENT_VM_HOME'])
  end

  def test_backend_does_not_load_operational_code_or_write_state
    backend = File.expand_path('../lib/completion.rb', __dir__)
    body = "require #{backend.dump}; abort 'loaded VM code' if $LOADED_FEATURES.any? { |file| file.end_with?('/core.rb') }; puts AgentVM::Completion.complete(['snapshot', 'restore', ''])"
    before = Dir.glob(File.join(ENV['AGENT_VM_HOME'], '**', '*')).select { |path| File.file?(path) }.to_h { |path| [path, File.binread(path)] }
    output, error, status = Open3.capture3('/usr/bin/ruby', '-e', body)
    assert status.success?, error
    assert_equal "before-upgrade\n", output
    assert_equal before, before.keys.to_h { |path| [path, File.binread(path)] }
  end
end
