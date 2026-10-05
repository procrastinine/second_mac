require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/install'

class InstallResumeTest < Minitest::Test
  def setup
    @environment = ENV.to_h
    @tmp = File.realpath(Dir.mktmpdir('second-mac-resume-'))
    ENV['AGENT_VM_HOME'] = File.join(@tmp, 'state')
    ENV['TART_HOME'] = File.join(@tmp, 'tart')
    @config = AgentVM::DEFAULTS.merge('name'=>'resume-box', 'user'=>'builder', 'profiles'=>['base', 'web'])
  end

  def teardown
    ENV.replace(@environment)
    FileUtils.remove_entry(@tmp)
  end

  def test_host_dependency_permission_failure_retains_choices_and_credentials
    2.times do
      config = File.file?(File.join(AgentVM.state_root, 'resume-box/config.json')) ? AgentVM::VM.load('resume-box').config : @config
      installer = AgentVM::Installer.new(config)
      installer.define_singleton_method(:host_tools) { raise AgentVM::Error, 'Permission prompt not completed' }
      error = assert_raises(AgentVM::Error) { installer.run }
      assert_includes error.message, 'progress is saved'
      vm = AgentVM::VM.load('resume-box')
      assert_equal ['base', 'web'], vm.config['profiles']
      assert_equal 'preparing', vm.config['phase']
      current = %w[admin-password id_ed25519 id_ed25519.pub].map { |name| Digest::SHA256.file(vm.file(name)).hexdigest }
      assert_equal @credentials, current if @credentials
      @credentials = current
      refute vm.exists?
    end
  end

  def test_interruption_between_key_files_recovers_without_rotating_private_key
    vm = AgentVM::VM.new(@config)
    vm.save
    installer = AgentVM::Installer.new(@config)
    installer.credentials(vm)
    private_key = File.binread(vm.file('id_ed25519'))
    password = vm.password
    File.unlink(vm.file('id_ed25519.pub'))
    installer.credentials(vm)
    assert_equal private_key, File.binread(vm.file('id_ed25519'))
    assert_equal password, vm.password
    derived = AgentVM.run('/usr/bin/ssh-keygen', '-y', '-f', vm.file('id_ed25519'), capture:true).split[0,2]
    assert_equal derived, File.read(vm.file('id_ed25519.pub')).split[0,2]
  end

  def test_successful_guest_stages_are_skipped_and_failed_stage_is_retried
    vm = AgentVM::VM.new(@config.merge('phase'=>'bootstrap'))
    vm.save
    installer = AgentVM::Installer.new(vm.config)
    calls = []
    installer.install_step(vm, 'guest_base') { calls << :base }
    assert_raises(AgentVM::Error) do
      installer.install_step(vm, 'guest_tools') { calls << :failed_tools; raise AgentVM::Error, 'guest shut down' }
    end
    resumed = AgentVM::VM.load(vm.name)
    assert_equal 'guest_tools', resumed.config['install_step']
    assert_equal ['guest_base'], resumed.config['completed_install_steps']
    installer.install_step(resumed, 'guest_base') { flunk 'Repeated completed CLT installation' }
    installer.install_step(resumed, 'guest_tools') { calls << :resumed_tools }
    assert_equal [:base, :failed_tools, :resumed_tools], calls
    assert_equal %w[guest_base guest_tools], AgentVM::VM.load(vm.name).config['completed_install_steps']
  end

  def test_missing_previously_booted_disk_is_never_recreated
    vm = AgentVM::VM.new(@config.merge('phase'=>'bootstrap'))
    vm.save
    installer = AgentVM::Installer.new(vm.config)
    installer.define_singleton_method(:host_tools) { flunk 'Tried to install a replacement OS' }
    error = assert_raises(AgentVM::Error) { installer.run }
    assert_includes error.message, 'VM disk is missing'
  end

  def test_interrupted_release_extraction_is_replaced_using_verified_cached_archive
    installer = AgentVM::Installer.new(@config)
    cache = File.join(AgentVM.state_root, 'downloads')
    FileUtils.mkdir_p(cache)
    contents = File.join(@tmp, 'release')
    AgentVM.write(File.join(contents, 'tool'), 'complete binary')
    archive = File.join(cache, 'example-release.tar.gz')
    AgentVM.run('/usr/bin/tar', '-czf', archive, '-C', contents, '.')
    digest = 'sha256:' + Digest::SHA256.file(archive).hexdigest
    metadata = {'tag_name'=>'release', 'assets'=>[{'name'=>'asset.tar.gz', 'digest'=>digest, 'browser_download_url'=>'https://example.invalid/asset'}]}
    installer.define_singleton_method(:download) do |url, destination|
      raise 'Redownloaded an already verified archive' unless url.include?('/releases/latest')
      AgentVM.json_write(destination, metadata)
    end
    target = File.join(cache, 'example-release')
    AgentVM.write(File.join(target, 'tool'), 'incomplete binary')
    2.times do
      result = installer.release('example', 'asset.tar.gz', 'tool')
      assert_equal 'complete binary', File.binread(result)
      assert_equal digest, File.read(File.join(target, '.archive-sha256'))
    end
    assert_empty Dir.glob(File.join(cache, '.release-*'))
  end

  def test_host_integration_retry_does_not_reenter_guest_setup
    vm = AgentVM::VM.new(@config.merge('phase'=>'integrating'))
    FileUtils.mkdir_p(vm.tart_directory)
    vm.save
    2.times do |attempt|
      installer = AgentVM::Installer.new(AgentVM::VM.load(vm.name).config)
      installer.define_singleton_method(:host_tools) { flunk 'Repeated host dependency setup' }
      installer.define_singleton_method(:stage) { |*| flunk 'Repeated guest staging' }
      installer.define_singleton_method(:integrations) { |*| raise AgentVM::Error, 'Shell permission not granted' if attempt.zero? }
      if attempt.zero?
        assert_raises(AgentVM::Error) { installer.run }
        assert_equal 'integrating', AgentVM::VM.load(vm.name).config['phase']
      else
        assert_output(/Ready:/) { installer.run }
        assert_equal 'ready', AgentVM::VM.load(vm.name).config['phase']
      end
    end
  end

  def test_first_boot_retry_reuses_existing_disk_instead_of_restoring_again
    vm = AgentVM::VM.new(@config.merge('phase'=>'bootstrap', 'sharing'=>'none', 'setup_method'=>'native'))
    vm.save
    installer = AgentVM::Installer.new(vm.config)
    installer.credentials(vm)
    FileUtils.mkdir_p(vm.tart_directory)
    disk = File.join(vm.tart_directory, 'disk.img')
    AgentVM.write(disk, 'already installed macOS')
    AgentVM.write(vm.file('known-hosts'), 'fixture')
    vm.define_singleton_method(:render_host) { }
    vm.define_singleton_method(:exclude_backup) { }
    vm.define_singleton_method(:running?) { true }
    vm.define_singleton_method(:ssh) { |*, **| '' }
    installer.define_singleton_method(:host_tools) { }
    installer.define_singleton_method(:stage) { |*| raise AgentVM::Error, 'Reached existing guest setup' }
    AgentVM::VM.stub(:new, vm) do
      AgentVM::Images.stub(:new, lambda { |*| flunk 'Restored the existing OS again' }) do
        error = nil
        capture_io { error = assert_raises(AgentVM::Error) { installer.run } }
        assert_includes error.message, 'Reached existing guest setup'
      end
    end
    assert_equal 'already installed macOS', File.binread(disk)
    assert_equal 'bootstrap', AgentVM::VM.load(vm.name).config['phase']
  end

  def test_ui_build_and_image_work_overlap_and_join_before_provisioning
    require_relative '../lib/ui-build'
    vm = AgentVM::VM.new(@config.merge('ui_enabled'=>true, 'phase'=>'creating'))
    vm.save
    started, release = Queue.new, Queue.new
    builder = Object.new
    builder.define_singleton_method(:ready?) { false }
    builder.define_singleton_method(:install) { started << true; release.pop; '/completed/tart' }
    installer = AgentVM::Installer.new(vm.config)
    result = nil
    AgentVM::UIBuild.stub(:new, builder) do
      capture_io do
        result = installer.prepare_ui_while(vm) do
          Timeout.timeout(5) { started.pop }
          release << true
          :image_complete
        end
      end
    end
    assert_equal :image_complete, result
    assert_equal '/completed/tart', AgentVM::VM.load(vm.name).config['ui_tart']
    assert_equal 0600, File.stat(vm.file('ui-build.log')).mode & 0777
  end

  def test_failed_parallel_build_preserves_the_completed_os_for_resume
    require_relative '../lib/ui-build'
    vm = AgentVM::VM.new(@config.merge('ui_enabled'=>true, 'phase'=>'creating'))
    vm.save
    image_ready = Queue.new
    builder = Object.new
    builder.define_singleton_method(:ready?) { false }
    builder.define_singleton_method(:install) { image_ready.pop; raise AgentVM::Error, 'Compiler interrupted' }
    installer = AgentVM::Installer.new(vm.config)
    AgentVM::UIBuild.stub(:new, builder) do
      capture_io do
        assert_raises(AgentVM::Error) do
          installer.prepare_ui_while(vm) do
            AgentVM.write(File.join(vm.tart_directory,'disk.img'), 'completed OS')
            image_ready << true
          end
        end
      end
    end
    assert_equal 'completed OS', File.read(File.join(vm.tart_directory,'disk.img'))
    assert_equal 'creating', AgentVM::VM.load(vm.name).config['phase']
  end

  def test_image_failure_cancels_and_reaps_the_parallel_build_process
    require_relative '../lib/ui-build'
    vm = AgentVM::VM.new(@config.merge('ui_enabled'=>true))
    vm.save
    pid_file = File.join(@tmp, 'compiler-pid')
    builder = Object.new
    builder.define_singleton_method(:ready?) { false }
    builder.define_singleton_method(:install) do
      AgentVM.run('/usr/bin/ruby', '-e', 'File.write(ARGV[0], Process.pid.to_s); sleep 30', pid_file, timeout:40)
    end
    AgentVM::UIBuild.stub(:new, builder) do
      capture_io do
        error = assert_raises(AgentVM::Error) do
          AgentVM::Installer.new(vm.config).prepare_ui_while(vm) do
            Timeout.timeout(5) { sleep 0.01 until File.file?(pid_file) }
            raise AgentVM::Error, 'Restore interrupted'
          end
        end
        assert_includes error.message, 'Restore interrupted'
      end
    end
    assert_raises(Errno::ESRCH) { Process.kill(0, Integer(File.read(pid_file))) }
  end

  def test_disabled_or_cached_ui_runs_image_work_without_compilation
    require_relative '../lib/ui-build'
    vm = AgentVM::VM.new(@config)
    installer = AgentVM::Installer.new(vm.config)
    AgentVM::UIBuild.stub(:new, ->(*) { flunk 'UI is disabled' }) do
      assert_equal :done, installer.prepare_ui_while(vm) { :done }
    end
    vm.config['ui_enabled'] = true
    builder = Object.new
    builder.define_singleton_method(:ready?) { true }
    builder.define_singleton_method(:install) { raise 'Cached UI must not compile' }
    AgentVM::UIBuild.stub(:new, builder) do
      assert_equal :done, installer.prepare_ui_while(vm) { :done }
    end
  end

  def test_softnet_authorization_uses_native_prompt_outside_a_terminal
    installer = AgentVM::Installer.new(@config)
    file = Struct.new(:uid, :mode).new(0, 04755)
    file.define_singleton_method(:setuid?) { true }
    path = "/example dir/quote'and-dollar$tool"
    calls = []
    File.stub(:stat, file) do
      AgentVM.stub(:run, ->(*args, **options) { calls << [args,options] }) do
        capture_io { installer.authorize_softnet(path, interactive:false) }
        capture_io { installer.authorize_softnet(path, interactive:true) }
      end
    end
    assert_equal '/usr/bin/osascript', calls[0][0][0]
    assert_includes calls[0][0][2], 'with administrator privileges'
    expected = Shellwords.join(['/usr/sbin/chown','root:wheel',path]) + ' && ' + Shellwords.join(['/bin/chmod','4755',path])
    assert_equal expected, calls[0][0].last
    assert_equal ['/usr/bin/sudo','/bin/sh','-c',expected], calls[1][0]
  end

  def test_guest_installer_lock_survives_exec_and_blocks_a_second_installer
    script = File.expand_path('../guest/setup-lock.rb', __dir__)
    lock = File.join(@tmp, 'guest/install.lock')
    ready = File.join(@tmp, 'ready')
    child = Process.spawn('/usr/bin/ruby', script, lock, '/usr/bin/ruby', '-e', 'File.write(ARGV[0], "ready"); sleep 30', ready)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until File.file?(ready)
      flunk 'Locked child did not start' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
    _, error, status = Open3.capture3('/usr/bin/ruby', script, lock, '--check')
    refute status.success?
    assert_includes error, 'still running'
    Process.kill('TERM', child)
    Process.wait(child)
    child = nil
    _, error, status = Open3.capture3('/usr/bin/ruby', script, lock, '--check')
    assert status.success?, error
  ensure
    Process.kill('TERM', child) if child
    Process.wait(child) if child
  end

  def test_inventory_collection_survives_disconnect_after_guest_file_removal
    vm = AgentVM::VM.new(@config)
    vm.save
    home = File.join(@tmp, 'guest-home')
    vm.define_singleton_method(:home) { home }
    guest_inventory = File.join(home, '.local/share/agent-vm/versions.txt')
    AgentVM.write(guest_inventory, "tool current-version\n")
    disconnected = false
    vm.define_singleton_method(:ssh) do |*args, **options|
      result = AgentVM.run(*args, **options)
      if args.first == '/bin/rm' && !disconnected
        disconnected = true
        raise AgentVM::Error, 'Connection lost after deleting temporary inventory'
      end
      result
    end
    installer = AgentVM::Installer.new(@config)
    assert_raises(AgentVM::Error) { installer.collect_versions(vm) }
    refute File.exist?(guest_inventory)
    saved = File.binread(vm.file('versions.txt'))
    assert_includes saved, 'tool current-version'
    installer.collect_versions(vm)
    assert_equal saved, File.binread(vm.file('versions.txt'))
  end
end
