require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/agents'
require_relative '../lib/credentials'

class AgentsTest < Minitest::Test
  def with_installer(fail_install: false)
    Dir.mktmpdir('agent-selection-') do |directory|
      vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('profiles'=>%w[base web], 'agents'=>%w[pi codex]))
      calls, saved = [], []
      vm.define_singleton_method(:running?) { true }
      vm.define_singleton_method(:start) { raise 'Already running' }
      vm.define_singleton_method(:with_lifecycle_lock) { |&block| block.call }
      vm.define_singleton_method(:save) { saved << config['agents'].dup }
      vm.define_singleton_method(:ssh) do |*args, **options|
        calls << [args, options]
        raise AgentVM::Error, 'Install interrupted' if fail_install && args[1].to_s.end_with?('install-agents.sh')
        ''
      end
      installer = Object.new
      installer.define_singleton_method(:stage) do |target, **options|
        calls << [[:stage], options]
        target.save # Real staging persists the bundled configuration.
      end
      AgentVM::Installer.stub(:new, installer) { yield vm, calls, saved }
    end
  end
  def test_add_preserves_other_agents_and_only_installs_explicit_names
    with_installer do |vm, calls, saved|
      capture_io { AgentVM::Agents.new(vm).command(%w[add claude claude]) }
      assert_equal %w[pi codex claude], saved.last
      installation = calls.find { |args, _| args[1].to_s.end_with?('install-agents.sh') }
      assert_equal ['claude'], installation.first.drop(2)
      assert_equal({bootstrap:false}, calls.find { |args, _| args == [:stage] }.last)
      assert_equal ['/bin/rm', '-rf', vm.home + '/.cache/agent-vm-setup'], calls.last.first
    end
  end
  def test_failure_restores_selection_and_cleans_staging_for_retry
    with_installer(fail_install:true) do |vm, calls, saved|
      assert_raises(AgentVM::Error) { AgentVM::Agents.new(vm).add(['claude']) }
      assert_equal %w[pi codex claude], saved.first
      assert_equal %w[pi codex], saved.last
      restored = calls.find { |args, _| args.first == '/usr/bin/tee' }.last.fetch(:input)
      assert_equal %w[pi codex], JSON.parse(restored).fetch('agents')
      assert_equal '/bin/rm', calls.last.first.first
    end
  end
  def test_invalid_names_never_start_or_stage_a_guest
    with_installer do |vm, calls, saved|
      [[], ['unknown'], %w[pi --help]].each do |names|
        assert_raises(AgentVM::Error) { AgentVM::Agents.new(vm).add(names) }
      end
      assert_empty calls
      assert_empty saved
    end
  end
  def test_adding_pi_offers_host_credentials_and_leaves_skipped_setup_disabled
    with_installer do |vm, calls, _saved|
      vm.config['agents'] = ['codex']
      vm.config['credential_relays'] = []
      relay = Object.new
      relay.define_singleton_method(:set) { |_| raise 'Skipped credentials must not enable a relay' }
      relay.define_singleton_method(:start) {}
      AgentVM::HostCredentials.stub(:offer_pi, false) do
        AgentVM::Credentials.stub(:new, relay) do
          capture_io { AgentVM::Agents.new(vm).add(['pi']) }
        end
      end
      assert_equal %w[codex pi], vm.config['agents']
      assert_equal [], vm.config['credential_relays']
      assert calls.any? { |args, _| args[1].to_s.end_with?('install-agents.sh') && args.last == 'pi' }
    end
  end
  def test_adding_pi_can_accept_host_credentials_without_prompting_on_reinstall
    with_installer do |vm, _calls, _saved|
      vm.config['agents'] = ['codex']
      vm.config['credential_relays'] = []
      choices = []
      relay = Object.new
      relay.define_singleton_method(:set) { |mode| choices << mode }
      relay.define_singleton_method(:start) {}
      AgentVM::Credentials.stub(:new, relay) do
        AgentVM::HostCredentials.stub(:offer_pi, true) do
          capture_io { AgentVM::Agents.new(vm).add(['pi']) }
        end
        assert_equal ['on'], choices
        AgentVM::HostCredentials.stub(:offer_pi, -> { flunk 'Already installed Pi asked again' }) do
          capture_io { AgentVM::Agents.new(vm).add(['pi']) }
        end
        assert_equal ['on'], choices
      end
    end
  end
  def test_adding_pi_preserves_existing_host_access_or_disables_it_after_skipping_a_missing_key
    with_installer do |vm, _calls, _saved|
      vm.config['credential_relays'] = ['openrouter']
      choices = []
      relay = Object.new
      relay.define_singleton_method(:set) { |mode| choices << mode }
      relay.define_singleton_method(:start) {}
      AgentVM::Credentials.stub(:new, relay) do
        AgentVM::HostCredentials.stub(:offer_pi, -> { flunk 'Saved grant must not ask for new consent' }) do
          vm.config['agents'] = ['codex']
          AgentVM::HostCredentials.stub(:available?, true) do
            capture_io { AgentVM::Agents.new(vm).add(['pi']) }
          end
          assert_empty choices
          vm.config['agents'] = ['codex']
          AgentVM::HostCredentials.stub(:available?, false) do
            AgentVM::HostCredentials.stub(:prompt, false) do
              capture_io { AgentVM::Agents.new(vm).add(['pi']) }
            end
          end
          assert_equal ['off'], choices
        end
      end
    end
  end
  def test_guest_installer_validates_all_names_before_running_any_module
    Dir.mktmpdir('agent-modules-') do |directory|
      FileUtils.mkdir_p(File.join(directory, 'agents'))
      FileUtils.mkdir_p(File.join(directory, '.config'))
      FileUtils.cp(File.expand_path('../guest/install-agents.sh', __dir__), directory)
      File.write(File.join(directory, 'privacy.env'), '')
      AgentVM.json_write(File.join(directory, 'config.json'), {'agents'=>%w[pi codex claude]})
      %w[pi codex claude].each do |name|
        File.write(File.join(directory, "agents/#{name}.sh"), "printf '%s\\n' #{name} >> \"$AGENT_TEST_LOG\"\n")
      end
      log = File.join(directory, 'installed')
      environment = {'HOME'=>directory, 'AGENT_TEST_LOG'=>log}
      script = File.join(directory, 'install-agents.sh')
      _, error, result = Open3.capture3(environment, '/bin/bash', script, 'claude')
      assert result.success?, error
      assert_equal "claude\n", File.read(log)
      _, _, result = Open3.capture3(environment, '/bin/bash', script, 'pi', 'invalid')
      refute result.success?
      assert_equal "claude\n", File.read(log)
      File.unlink(log)
      _, error, result = Open3.capture3(environment, '/bin/bash', script)
      assert result.success?, error
      assert_equal "pi\ncodex\nclaude\n", File.read(log)
    end
  end
end
