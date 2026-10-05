require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/menu'

class MenuTest < Minitest::Test
  def setup
    @old_state = ENV['AGENT_VM_HOME']
    @old_tart = ENV['TART_HOME']
    @tmp = File.realpath(Dir.mktmpdir('agent-vm-menu-'))
    ENV['AGENT_VM_HOME'] = File.join(@tmp, "state space ' quote")
    ENV['TART_HOME'] = File.join(@tmp, 'tart')
    @vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('share'=>File.join(@tmp, 'share')))
    @vm.save
    AgentVM.write(@vm.file('menu-on.png'), 'on-icon')
    AgentVM.write(@vm.file('menu-off.png'), 'off-icon')
    @vm.define_singleton_method(:running?) { false }
    @vm.define_singleton_method(:rpc) { |*| raise 'Polling a stopped VM must not contact or start it' }
    @menu = AgentVM::Menu.new(@vm)
  end
  def teardown
    ENV['AGENT_VM_HOME'] = @old_state
    ENV['TART_HOME'] = @old_tart
    FileUtils.remove_entry(@tmp)
  end
  def render(mounted)
    AgentVM::Files.stub(:new, Struct.new(:mounted?).new(mounted)) { @menu.render }
  end
  def test_stopped_menu_is_icon_only_and_has_obvious_mount_action
    output = render(false)
    assert_equal '', output.lines.first.split('|').first.strip
    assert_includes output.lines.first, 'templateImage=' + Base64.strict_encode64('off-icon')
    assert_match(/Start & Mount VM disk in Finder \| href=file:/, output)
    actions = {
      'Check VM tools updates…'=>['update', '--check'],
      'Update VM tools…'=>['update'],
      'Check guest macOS updates…'=>['update', '--macos', '--check'],
      'Update guest macOS… (may restart)'=>['update', '--macos']
    }
    assert_equal 4, output.lines.count { |line| line.match?(/^--(?:Check|Update) .*(?:updates|tools|macOS)/) }
    actions.each do |label, expected|
      row = output.lines.find { |line| line.start_with?('--' + label + ' | href=file:') }
      refute_nil row, "Missing menu action: #{label}"
      path = URI::DEFAULT_PARSER.unescape(URI.parse(row.split('href=').last.strip).path)
      args = Shellwords.split(File.read(path).lines.last.sub('exec ', ''))
      assert_equal [@vm.file('command'), *expected], args
    end
    refute_match(/VM system|Tart runtime|Runtime features|Use (?:auto|standard|custom)/, output)
    refute_match(/diagnostics|menu action log/i, output)
    refute_match(/\b(?:color|bash)=/, output)
    labels = output.lines.grep(/Host and LAN|No forwarded ports|released while stopped/)
    assert_equal 3, labels.length
    labels.each do |line|
      assert_includes line, 'ansi=true'
      refute_match(/\b(?:href|refresh|color)=/, line)
    end
  end
  def test_mounted_disk_has_open_and_unmount_controls_before_submenus
    output = render(true)
    assert_includes output, 'Open mounted VM disk | href=file:'
    assert_includes output, 'Unmount VM disk | href=file:'
    assert_operator output.index('Unmount VM disk'), :<, output.index('Tmux sessions')
  end
  def test_service_autostart_and_key_entry_use_common_commands_without_a_guest_probe
    AgentVM::HostCredentials.prepare
    output = render(false)
    assert_match(/^--Add key & enable OpenRouter… \| href=file:/, output)
    assert_match(/^--Enable OpenRouter at VM start \| href=file:/, output)
    refute_match(/Start OpenRouter for this run/, output)
    AgentVM::HostCredentials.store('fixture-key')
    @vm.config['credential_relays'] = ['openrouter']; @vm.save
    output = render(false)
    assert_match(/^--Change key & enable OpenRouter… \| href=file:/, output)
    assert_match(/^--Disable OpenRouter at VM start \| href=file:/, output)
    line = output.lines.find { |row| row.include?('OpenRouter:') }
    assert_includes line, 'ansi=true'
    refute_includes line, 'href='
    action = output.lines.find { |row| row.start_with?('--Disable OpenRouter at VM start |') }
    path = URI::DEFAULT_PARSER.unescape(URI.parse(action.split('href=').last.strip).path)
    plist = JSON.parse(AgentVM.run('/usr/bin/plutil', '-convert', 'json', '-o', '-', File.join(path, 'Contents/Info.plist'), capture:true))
    assert_equal ['menu-action', 'credential-relay', 'autostart', 'off'], plist.fetch('ActionArguments')
    action = output.lines.find { |row| row.start_with?('--Change key & enable OpenRouter… |') }
    path = URI::DEFAULT_PARSER.unescape(URI.parse(action.split('href=').last.strip).path)
    assert_equal [@vm.file('command'), 'auth', 'set'], Shellwords.split(File.read(path).lines.last.sub('exec ', ''))
  end

  def test_service_current_run_buttons_preserve_autostart_and_old_copies_keep_old_commands
    AgentVM::HostCredentials.store('fixture-key')
    @vm.define_singleton_method(:running?) { true }
    @vm.define_singleton_method(:running_pid) { 123 }
    @vm.define_singleton_method(:ui_available?) { true }
    @vm.config['credential_relays'] = ['openrouter']
    @vm.config['guest_control'] = true
    @vm.save
    rows = @menu.service_lines(@vm, ['menu-action'], busy:false, prefix:'--')
    {'Stop OpenRouter for this run'=>'credential-relay', 'Stop Mac control for this run'=>'guest-control'}.each do |label, command|
      row = rows.find { |line| line.start_with?('--'+label+' |') }
      refute_nil row
      path = URI::DEFAULT_PARSER.unescape(URI.parse(row.split('href=').last.strip).path)
      plist = JSON.parse(AgentVM.run('/usr/bin/plutil', '-convert', 'json', '-o', '-', File.join(path, 'Contents/Info.plist'), capture:true))
      assert_equal ['menu-action', command, 'off', '--once'], plist['ActionArguments']
    end
    @vm.config['throwaway'] = {'id'=>'0123abcd'}
    AgentVM.write(@vm.file('runtime/lib/credentials.rb'), 'old runtime')
    rows = @menu.service_lines(@vm, ['menu-action','throwaway','0123abcd'], busy:false, prefix:'------')
    assert rows.any? { |line| line.start_with?('------Disable OpenRouter host key |') }
    refute rows.any? { |line| line.include?('at VM start') || line.include?('for this run') }
  end

  def test_saved_memory_menu_offers_resume_without_copying_the_suspended_disk
    AgentVM.write(File.join(@vm.tart_directory, 'state.vzvmsave'), 'saved memory')
    output = render(false)
    assert_includes output, 'Suspended · memory saved'
    assert_match(/^Resume \| href=file:/, output)
    assert_match(/^Resume & Shell.*href=file:/, output)
    refute_match(/^Start \|/, output)
    refute_match(/Create Throwaway.*href=/, output)
  end
  def test_guest_session_text_cannot_inject_menu_or_host_commands
    @vm.define_singleton_method(:running?) { true }
    @vm.define_singleton_method(:rpc) do |*args, **|
      args.first.end_with?('tmux') ? "$17\tname | bash=evil `touch bad`\t1\t0\n" : "CPU usage: 1% user\nPhysMem: 1G used\n"
    end
    output = render(false)
    row = output.lines.find { |line| line.start_with?('--name ') }
    assert_equal 1, row.count('|')
    url = row.split('href=').last.strip
    path = URI::DEFAULT_PARSER.unescape(URI.parse(url).path)
    argv = Shellwords.split(File.read(path).lines.last.sub('exec ', ''))
    assert_equal [@vm.file('command'), 'tmux', '$17'], argv
  end
  def test_running_menu_has_storage_restart_and_no_agents_submenu
    @vm.config['agents'] = %w[pi codex]
    @vm.define_singleton_method(:running?) { true }
    @vm.define_singleton_method(:rpc) do |*args, **|
      case File.basename(args.first)
      when 'df' then "Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/disk1 100000 20000 10485760 20% /System/Volumes/Data\n"
      when 'top' then "CPU usage: 1% user\nPhysMem: 1G used\n"
      else ''
      end
    end
    AgentVM.write(File.join(@vm.tart_directory, 'disk.img'), 'test fixture')
    output = render(false)
    refute_includes output.lines.map(&:strip), 'Agents'
    assert_match(/^Restart VM and macOS \| href=file:/, output)
    assert_match(/^Shut Down \| href=file:/, output)
    assert_match(/^Restart with GUI \| href=file:/, output)
    assert_includes output, 'Disk capacity: 100 GB'
    assert_includes output, 'Host disk:'
    assert_includes output, 'Guest free space: 10.0 GiB'
  end
  def test_gui_menu_offers_live_show_and_hide
    @vm.define_singleton_method(:running?) { true }
    @vm.define_singleton_method(:rpc) { |*, **| '' }
    gui = Object.new
    gui.define_singleton_method(:active?) { true }
    gui.define_singleton_method(:hidden?) { true }
    AgentVM::GUI.stub(:new, gui) do
      output = render(false)
      assert_match(/^Show desktop \|/, output)
      refute_match(/^Hide desktop/, output)
      refute_match(/^Restart without GUI \|/, output)
      gui.define_singleton_method(:hidden?) { false }
      output = render(false)
      assert_match(/^Hide desktop \(/, output)
      refute_match(/^Show desktop/, output)
      @vm.config['ui_enabled'] = true
      output = render(false)
      assert_match(/^Hide desktop \(/, output)
      refute_match(/^Restart (?:with|without) GUI/, output)
    end
  end

  def test_custom_headless_menu_offers_show_instead_of_a_restart
    @vm.define_singleton_method(:running?) { true }
    @vm.define_singleton_method(:rpc) { |*, **| '' }
    @menu.define_singleton_method(:live_viewer?) { |_| true }
    output=render(false)
    assert_match(/^Show desktop \|/, output)
    refute_match(/^Restart with GUI/, output)
  end
  def test_throwaway_menu_polls_without_booting_and_lights_icon_when_only_copy_runs
    copy = AgentVM::VM.new(@vm.config.merge('name'=>'copy-box', 'phase'=>'ready', 'sharing'=>'none',
      'throwaway'=>{'id'=>'0123abcd', 'source'=>@vm.name, 'created_at'=>'2026-10-01T00:00:00Z'}))
    copy.save
    AgentVM.write(File.join(copy.tart_directory, 'disk.img'), 'fixture')
    copy.define_singleton_method(:running?) { true }
    copy.define_singleton_method(:rpc) { |*| raise 'Polling throwaways must not contact guests' }
    AgentVM::Throwaway.stub(:entries, [copy]) do
      output = render(false)
      assert_includes output.lines.first, Base64.strict_encode64('on-icon')
      assert_includes output, '0123abcd · copy-box · Running'
      %w[Shell Restart].each { |label| assert_match(/^----#{label}.*href=file:/, output) }
      refute_match(/Delete Throwaway/, output)
      refute_includes output, 'Shut Down Main & Create'
      row = output.lines.find { |line| line.start_with?('----Shell') }
      path = URI::DEFAULT_PARSER.unescape(URI.parse(row.split('href=').last.strip).path)
      assert_equal [@vm.file('command'), 'throwaway', 'ssh', '0123abcd'], Shellwords.split(File.read(path).lines.last.sub('exec ', ''))
      copy.define_singleton_method(:running?) { false }
      output = render(false)
      assert_includes output.lines.first, Base64.strict_encode64('off-icon')
      assert_match(/Delete Throwaway.*href=file:/, output)
      row = output.lines.find { |line| line.include?('Delete Throwaway') }
      path = URI::DEFAULT_PARSER.unescape(URI.parse(row.split('href=').last.strip).path)
      plist = File.read(File.join(path, 'Contents/Info.plist'))
      assert_includes plist, 'ActionConfirmation'
      assert_includes plist, '0123abcd'
    end
  end
  def test_incomplete_copy_has_no_boot_controls_and_live_source_copy_requires_confirmation
    copy = AgentVM::VM.new(@vm.config.merge('name'=>'copy-box', 'phase'=>'copying',
      'throwaway'=>{'id'=>'0123abcd', 'source'=>@vm.name}))
    copy.define_singleton_method(:running?) { false }
    lines = @menu.throwaway_lines([copy], busy:false, source_running:true).join("\n")
    assert_includes lines, 'Incomplete'
    assert_includes lines, 'Delete Throwaway'
    refute_match(/^----(?:Start|Shell|Mount)/, lines)
    row = lines.lines.find { |line| line.include?('Shut Down Main & Create') }
    path = URI::DEFAULT_PARSER.unescape(URI.parse(row.split('href=').last.strip).path)
    assert_includes File.read(File.join(path, 'Contents/Info.plist')), 'ActionConfirmation'
  end
  def test_old_throwaway_keeps_its_original_network_controls
    copy = AgentVM::VM.new(@vm.config.merge('name'=>'copy-box', 'phase'=>'ready',
      'throwaway'=>{'id'=>'0123abcd', 'source'=>@vm.name}))
    rows = @menu.network_lines(copy, [], busy:false, prefix:'----').join("\n")
    assert_includes rows, 'original networking'
    refute_includes rows, 'href='
  end
  def test_throwaway_menu_dispatches_to_its_saved_runtime
    copy = AgentVM::VM.new(@vm.config.merge('name'=>'copy-box', 'phase'=>'ready',
      'throwaway'=>{'id'=>'0123abcd', 'source'=>@vm.name}))
    AgentVM.write(copy.file('runtime/lib/menu.rb'), '# saved runtime')
    finder = Object.new
    finder.define_singleton_method(:find) { |_| copy }
    @menu.define_singleton_method(:perform_vm_action) { |*| raise 'Must not use the main runtime' }
    calls = []
    AgentVM::Throwaway.stub(:new, finder) do
      AgentVM.stub(:run, ->(*args, **options) { calls << args }) do
        @menu.perform('throwaway', '0123abcd', 'network', 'vpn')
      end
    end
    assert_equal ['/usr/bin/ruby', '-I', copy.file('runtime/lib'), '-rmenu'], calls.first.take(4)
    assert_equal [copy.name, 'network', 'vpn'], calls.first.last(3)
  end
  def test_reinstall_refreshes_only_this_plugin_without_rewriting_unchanged_script
    require_relative '../lib/swiftbar'
    @menu.define_singleton_method(:build_helper) { }
    directory = File.join(@tmp, 'plugins')
    ok = Struct.new(:success?).new(true)
    calls = []
    @menu.define_singleton_method(:system) { |*args, **_| calls << args; true }
    AgentVM::SwiftBar.stub(:application, '/Applications/SwiftBar.app') do
      Open3.stub(:capture2, [directory, ok]) do
        AgentVM.stub(:run, ->(*args, **_) { calls << args }) do
          capture_io { @menu.install(update_app:false) }
          path = @vm.config.fetch('swiftbar_plugin')
          inode = File.stat(path).ino
          capture_io { @menu.install(update_app:false) }
          assert_equal inode, File.stat(path).ino
          assert_includes File.read(path), '<swiftbar.refreshOnOpen>false'
        end
      end
    end
    refute calls.flatten.any? { |arg| arg.include?('refreshallplugins') }
    assert_equal 2, calls.count { |args| args == ['/usr/bin/open', '-g', '-a', '/Applications/SwiftBar.app'] }
    refreshes = calls.select { |args| args.last.start_with?('swiftbar:') }
    assert_equal 2, refreshes.length
    assert refreshes.all? { |args| args.last == 'swiftbar://refreshplugin?name=' + CGI.escape(File.basename(@vm.config['swiftbar_plugin'])) }
  end
end
