require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/core'

class CLITest < Minitest::Test
  def test_lifecycle_help_and_invalid_options_never_touch_a_guest
    Dir.mktmpdir('cli-validation-') do |directory|
      environment = {'AGENT_VM_HOME'=>directory}
      cli = File.expand_path('../lib/cli.rb', __dir__)
      stub = <<~'RUBY'
        require File.join(File.dirname(ARGV.first), 'core')
        AgentVM::VM.define_singleton_method(:load) { |*| new(AgentVM::DEFAULTS.dup) }
        %i[start stop force_stop running?].each do |operation|
          AgentVM::VM.define_method(operation) { |*| abort 'UNEXPECTED_GUEST_OPERATION' }
        end
        load ARGV.shift
      RUBY
      %w[start stop force-stop restart].each do |command|
        ['--help', '--invalid-option'].each do |argument|
          out, err, status = Open3.capture3(environment, '/usr/bin/ruby', '-e', stub, cli, command, argument)
          refute_includes out + err, 'UNEXPECTED_GUEST_OPERATION'
          assert_includes out + err, 'Usage: vm ' + command
          assert_equal argument == '--help', status.success?
        end
      end
      [%w[ports host abc], %w[ports guest 65536], %w[ports host 80],
       %w[ports guest 8080 22], %w[ports host 8080 9000 extra],
       %w[tmux first second], %w[agents add unknown]].each do |args|
        out, err, status = Open3.capture3(environment, '/usr/bin/ruby', '-e', stub, cli, *args)
        refute status.success?, args.inspect
        refute_includes out + err, 'UNEXPECTED_GUEST_OPERATION'
      end
    end
  end
end
