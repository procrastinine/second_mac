require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require_relative '../lib/command-catalog'

class HelpTest < Minitest::Test
  CLI = File.expand_path('../lib/cli.rb', __dir__)

  def test_every_public_help_topic_returns_before_vm_code_is_loaded
    Dir.mktmpdir('vm-help-') do |directory|
      # One Ruby process exercises every real CLI entry path. Any accidental
      # load of core.rb or a handler fails, even if it would only read state.
      script = <<~'RUBY'
        require File.join(File.dirname(ARGV.first), 'command-catalog')
        cli = ARGV.shift
        topics = AgentVM::CommandCatalog::COMMANDS.keys
        requests = topics.flat_map do |topic|
          words = topic.split
          words.insert(2, 'aabbccdd') if words.first == 'throwaway' && (AgentVM::CommandCatalog::THROWAWAY_ACTIONS + ['access']).include?(words[1])
          [['help', *topic.split], [*words, '--help'], ['--name', 'uninstalled-box', *words, '-h']]
        end
        requests.concat([['--help'], ['help'], ['completion', 'bash'], ['completion', 'zsh']])
        $stdout = File.open(File::NULL, 'w')
        requests.each do |args|
          ARGV.replace(args)
          begin
            load cli
            abort "No help exit for #{args.inspect}"
          rescue SystemExit => error
            abort "Help failed: #{args.inspect}" unless error.success?
          end
          abort 'Loaded operational VM code' if $LOADED_FEATURES.any? { |file| file.end_with?('/core.rb') }
        end
      RUBY
      _output, error, status = Open3.capture3({'AGENT_VM_HOME'=>File.join(directory, 'missing')}, '/usr/bin/ruby', '-e', script, CLI)
      assert status.success?, error
      assert_empty Dir.children(directory)
    end
  end

  def test_nested_help_has_the_specific_usage_and_options
    output, error, status = Open3.capture3('/usr/bin/ruby', CLI, 'snapshot', 'restore', '--help')
    assert status.success?, error
    assert_includes output, 'Usage: vm snapshot restore NAME'
    refute_includes output, 'Daily use'
    assert_includes AgentVM::CommandCatalog.help('update'), '--second-mac-only'
    assert_includes AgentVM::CommandCatalog.help('throwaway network off'), 'vm throwaway network ID off'
  end

  def test_remote_help_arguments_are_not_swallowed
    [%w[ssh python --help], %w[sudo python --help], %w[ssh -- --help],
     %w[codex -- --help], %w[codex --model example --help],
     %w[throwaway ssh aabbccdd python --help], %w[throwaway script.sh --help],
     %w[throwaway create script.sh --help]].each do |args|
      assert_nil AgentVM::CommandCatalog.help_request(args), args.inspect
    end
    assert_equal 'ssh', AgentVM::CommandCatalog.help_request(%w[ssh --help])
    assert_equal 'throwaway ssh', AgentVM::CommandCatalog.help_request(%w[throwaway ssh aabbccdd --help])
  end

  def test_unknown_topics_fail_without_loading_vm_state
    Dir.mktmpdir('vm-help-invalid-') do |directory|
      output, error, status = Open3.capture3({'AGENT_VM_HOME'=>directory}, '/usr/bin/ruby', CLI, 'help', 'snapshot', 'typo')
      refute status.success?
      assert_empty output
      assert_includes error, 'Unknown help topic: snapshot typo'
      refute_includes error, 'No managed VM'
      assert_empty Dir.children(directory)
    end
  end

  def test_catalog_covers_public_dispatch_and_profile_and_permission_choices
    source = File.read(CLI)
    commands = source.lines.grep(/^  when '/).flat_map { |line| line.split(' then ').first.scan(/'([^']+)'/).flatten }
    commands -= %w[menu menu-action]
    assert_empty commands.uniq - AgentVM::CommandCatalog::COMMANDS.keys
    assert_equal AgentVM::CommandCatalog.children.map(&:path).sort, AgentVM::CommandCatalog::GROUPS.values.flatten.sort
    require_relative '../guest/permissions'
    choices = AgentVM::CommandCatalog::COMMANDS.fetch('permissions grant').arguments.last
    assert_equal GuestPermissions::SERVICES.keys.sort + ['all'], (choices - ['all']).sort + ['all']
  end

  def test_catalog_options_match_the_operational_option_parsers
    require_relative '../lib/update'
    require_relative '../lib/resources'
    require_relative '../lib/shares-cli'
    require_relative '../lib/throwaway'
    vm = AgentVM::VM.new(AgentVM::DEFAULTS.dup)
    {'update'=>[AgentVM::Update.new(vm), []], 'resources'=>[AgentVM::Resources.new(vm), []],
     'shares configure'=>[AgentVM::ShareSettings.new(vm), ['configure']],
     'throwaway'=>[AgentVM::Throwaway.new, []]}.each do |topic, (handler, args)|
      output, _error = capture_io { handler.command(args + ['--help']) }
      option_lines = output.lines.grep(/^\s+(?:-[a-z],\s+)?--/).join
      actual = option_lines.scan(/--(?:\[no-\])?[a-z][a-z-]*/).flat_map do |flag|
        flag.include?('[no-]') ? [flag.sub('[no-]', ''), flag.sub('[no-]', 'no-')] : [flag]
      end.uniq - ['--help']
      declared = AgentVM::CommandCatalog.option_specs(AgentVM::CommandCatalog::COMMANDS.fetch(topic)).keys
      assert_equal actual.sort, declared.sort, topic
    end
  end

  def test_cli_forwards_remote_help_and_strips_only_the_explicit_terminator
    stub = <<~'RUBY'
      require File.join(File.dirname(ARGV.first), 'core')
      require File.join(File.dirname(ARGV.first), 'guest-commands')
      AgentVM::VM.define_singleton_method(:load) { |*| new(AgentVM::DEFAULTS.merge('agents'=>['codex'])) }
      AgentVM::VM.define_method(:running?) { true }
      AgentVM::VM.define_method(:start) { abort 'Unexpected guest start' }
      AgentVM::VM.define_method(:ssh_args) { ['/fixture/ssh'] }
      AgentVM::GuestCommands.define_singleton_method(:sudo_line) { |args| puts JSON.generate(args); exit }
      define_singleton_method(:exec) { |*args| puts JSON.generate(args); exit }
      load ARGV.shift
    RUBY
    [%w[ssh python --help], %w[ssh -- python --help], %w[codex -- --help], %w[sudo -- python --help]].each do |args|
      output, error, status = Open3.capture3('/usr/bin/ruby', '-e', stub, CLI, *args)
      assert status.success?, error
      result = JSON.parse(output)
      expected = args.first == 'codex' ? 'codex --help' : 'python --help'
      assert_equal expected, args.first == 'sudo' ? result.join(' ') : result.last
    end
  end
end
