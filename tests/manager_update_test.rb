require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/install'

class ManagerUpdateTest < Minitest::Test
  def setup
    @environment = ENV.to_h
    @tmp = File.realpath(Dir.mktmpdir('second-mac-update-'))
    ENV['HOME'] = File.join(@tmp, 'different home')
    ENV['AGENT_VM_HOME'] = File.join(@tmp, 'private state')
    ENV['TART_HOME'] = File.join(@tmp, 'tart')
    ENV['SHELL'] = '/bin/zsh'
    ENV['PATH'] = File.join(Dir.home, '.local/bin') + ':/usr/bin:/bin:/usr/sbin:/sbin'
    @remote, @seed, @checkout = %w[remote seed checkout].map { |name| File.join(@tmp, name) }
    git(@tmp, 'init', '--bare', '--initial-branch=main', @remote)
    git(@tmp, 'clone', @remote, @seed)
    source = File.expand_path('..', __dir__)
    %w[lib guest packages agent-vm install.sh bootstrap.sh update.sh].each do |item|
      FileUtils.cp_r(File.join(source, item), @seed)
    end
    commit('initial manager')
    git(@seed, 'push', '-u', 'origin', 'main')
    git(@tmp, 'clone', @remote, @checkout)
    @vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('name'=>'test-box', 'user'=>'builder',
      'tart'=>'/usr/bin/false', 'phase'=>'ready', 'sharing'=>'none'))
    FileUtils.mkdir_p(@vm.tart_directory)
    AgentVM.write(File.join(@vm.tart_directory, 'config.json'), '{}')
    AgentVM.write(File.join(@vm.tart_directory, 'disk.img'), 'guest disk must remain unchanged')
    installer = AgentVM::Installer.new(@vm.config)
    installer.instance_variable_set(:@source, @checkout)
    installer.bundle(@vm)
    AgentVM.write(File.join(AgentVM.state_root, 'default'), @vm.name + "\n")
  end

  def teardown
    ENV.replace(@environment)
    FileUtils.remove_entry(@tmp)
  end

  def git(directory, *args)
    AgentVM.run('/usr/bin/git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', '-C', directory,
                *args, capture:true, timeout:30)
  end

  def commit(message)
    git(@seed, 'add', '.')
    git(@seed, 'commit', '-m', message)
  end

  def test_installed_command_fetches_and_executes_new_source_without_guest_operations
    # This code exists only in the future source release, not the installed
    # runtime. Seeing its output proves the updater executed the fetched code.
    File.open(File.join(@seed, 'lib/update.rb'), 'a') do |file|
      file.write <<~'RUBY'
        AgentVM::Update.prepend(Module.new do
          def perform_manager(**options)
            super
            puts 'UPDATED_MANAGER_EXECUTED'
          end
        end)
        %i[start stop launch ssh root rpc].each do |operation|
          AgentVM::VM.define_method(operation) { |*| raise "Unexpected guest operation: #{operation}" }
        end
      RUBY
    end
    commit('new manager release')
    git(@seed, 'push')
    disk = File.join(@vm.tart_directory, 'disk.img')
    before = [File.stat(disk).ino, Digest::SHA256.file(disk).hexdigest]
    output = AgentVM.run(@vm.file('runtime/agent-vm'), 'update', '--second-mac-only', capture:true, timeout:30)
    assert_includes output, '1 behind'
    assert_includes output, 'UPDATED_MANAGER_EXECUTED'
    assert_includes output, 'latest combined configuration will apply at its next managed start'
    assert_equal git(@seed, 'rev-parse', 'HEAD'), git(@checkout, 'rev-parse', 'HEAD')
    assert_equal File.read(File.join(@checkout, 'lib/update.rb')), File.read(@vm.file('runtime/lib/update.rb'))
    assert_equal before, [File.stat(disk).ino, Digest::SHA256.file(disk).hexdigest]
    assert File.executable?(File.join(Dir.home, '.local/bin/vm'))
    status = AgentVM.run(File.join(Dir.home, '.local/bin/vm'), 'status', capture:true)
    assert_includes status, '(stopped)'
    assert_output(/current repository/) { AgentVM::VM.load(@vm.name).verify_runtime }
    assert_empty git(@checkout, 'status', '--porcelain')
  end

  def test_update_script_preserves_default_and_explicit_scopes
    path = File.join(@tmp, 'wrapper')
    FileUtils.mkdir_p(path)
    FileUtils.cp(File.expand_path('../update.sh', __dir__), path)
    AgentVM.write(File.join(path, 'agent-vm'), "#!/usr/bin/ruby\nrequire 'json'\nputs JSON.generate(ARGV)\n", 0755)
    [[], ['--macos', '--check'], ['--second-mac-only', '--configuration']].each do |flags|
      [[], ['--name', 'test-box']].each do |selection|
        output = AgentVM.run(File.join(path, 'update.sh'), *selection, *flags, capture:true)
        assert_equal [*selection, 'update', *flags], JSON.parse(output)
      end
    end
  end
end
