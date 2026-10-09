require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require 'stringio'
require_relative '../guest/control-client'
require_relative '../lib/ui'

class ControlCommandsTest < Minitest::Test
  def test_key_duration_syntax_and_bounds
    assert_equal({'op'=>'key','key'=>'cmd+comma'}, GuestControlClient.payload(%w[key cmd+comma]))
    assert_equal({'op'=>'key','key'=>'right','hold_ms'=>500}, GuestControlClient.payload(%w[key right --hold-ms 500]))
    assert_equal 80, GuestControlClient.payload(%w[key --hold-ms 80 a])['hold_ms']
    %w[0 9 5001 -1 1.5 NaN Infinity].each do |value|
      assert_raises(MacControlCommands::Error) { GuestControlClient.payload(['key','a','--hold-ms',value]) }
    end
    [%w[key a --hold-ms], %w[key a --hold-ms 80 --hold-ms 90], %w[key a extra]].each do |args|
      assert_raises(MacControlCommands::Error) { GuestControlClient.payload(args) }
    end
  end
  def test_explicit_hold_requires_native_support_and_preserves_duration
    desktop = AgentVM::Desktop.new(Object.new)
    requests, features = [], []
    desktop.define_singleton_method(:request) do |value, **_|
      requests << value
      value['op'] == 'status' ? {'features'=>features,'key_hold_ms'=>80,'key_hold_range_ms'=>[10,5000]} : {'ok'=>true}
    end
    desktop.stub(:sleep, nil) do
      desktop.keyboard('a')
      assert_equal({'op'=>'key','code'=>0,'flags'=>0}, requests.last)
      assert_raises(AgentVM::Desktop::UnsupportedInput) { desktop.keyboard('right', hold_ms:500) }
      assert_equal %w[key status], requests.map { |r| r['op'] }
      assert desktop.capabilities['key_timing_update_pending']
      features << 'key-hold-v1'
      desktop.keyboard('cmd+shift+a', hold_ms:250)
      assert_equal({'op'=>'key','code'=>0,'flags'=>(1<<20)|(1<<17),'hold_ms'=>250}, requests.last)
      capability = desktop.capabilities
      assert capability['timed_keys']
      assert_equal 80, capability['key_hold_ms']
      assert_equal [10,5000], capability['key_hold_range_ms']
      refute capability['key_timing_update_pending']
    end
  end
  def test_typing_response_deadline_includes_native_holds_and_settling
    assert_equal 180, MacControlCommands.response_timeout('op'=>'key','hold_ms'=>5000)
    assert_equal 180, MacControlCommands.response_timeout('op'=>'type','text'=>'a' * 10)
    timeout = MacControlCommands.response_timeout('op'=>'type','text'=>'a' * 4096)
    assert_operator timeout, :>, 4096 * (0.08 + 0.15)
    assert_operator timeout, :<, 1800
    assert_equal timeout, MacControlCommands.response_timeout('op'=>'type','text'=>'a' * 10000)
  end
  def test_pointer_commands_and_validation_before_input
    assert_equal({'op'=>'click','x'=>2.5,'y'=>3.0,'button'=>'right','count'=>2}, GuestControlClient.payload(%w[click 2.5 3 --button right --count 2]))
    assert_equal 0.6, GuestControlClient.payload(%w[drag 1 2 900 700])['duration']
    assert_equal({'op'=>'scroll','x'=>100.0,'y'=>200.0,'dx'=>0.0,'dy'=>-350.0}, GuestControlClient.payload(%w[scroll up 350 --at 100 200]))
    [%w[click NaN 0], %w[click 0 768], %w[move -1 20], %w[click 0 0 --count 4],
     %w[click 0 0 --button wheel], %w[drag 0 0 1024 20], %w[drag 0 0 10 20 --duration 0],
     %w[scroll down -100], %w[scroll down 5000], %w[move 2 3 --extra]].each do |args|
      assert_raises(MacControlCommands::Error, args.inspect) { GuestControlClient.payload(args) }
    end
  end
  def test_text_is_prevalidated_and_never_partially_typed
    desktop = AgentVM::Desktop.new(Object.new)
    sent = []
    desktop.define_singleton_method(:key) { |code, flags:0| sent << [code, flags] }
    desktop.type("A\tB\n!")
    assert_equal [[0,1<<17],[48,0],[11,1<<17],[36,0],[18,1<<17]], sent
    sent.clear
    assert_raises(AgentVM::Error) { desktop.type('hello 日本語') }
    assert_empty sent
    desktop.keyboard('cmd+comma')
    desktop.keyboard('cmd+plus')
    desktop.keyboard('backspace')
    assert_equal [[43,1<<20],[24,(1<<20)|(1<<17)],[51,0]], sent
    assert_equal 'café', MacControlCommands.text(['café'], unicode:true)
    assert_raises(MacControlCommands::Error) { MacControlCommands.text(["hello\x1b[31m"]) }
    assert_equal '--help', MacControlCommands.text(%w[-- --help])
  end
  def test_legacy_viewer_keeps_basic_click_and_reports_new_input_without_dispatch
    desktop = AgentVM::Desktop.new(Object.new)
    sent = []
    desktop.define_singleton_method(:request) do |value, **_|
      sent << value
      value['op'] == 'status' ? {'version'=>1,'width'=>1024,'height'=>768} : {'ok'=>true}
    end
    desktop.pointer(GuestControlClient.payload(%w[click 10 20]))
    assert_equal({'op'=>'click','x'=>10.0,'y'=>20.0}, sent.first)
    assert_raises(AgentVM::Desktop::UnsupportedInput) { desktop.pointer(GuestControlClient.payload(%w[drag 0 0 100 100])) }
    assert_equal %w[click status], sent.map { |c| c['op'] }
    refute_includes desktop.capabilities['operations'], 'drag'
  end
  def test_screenshot_file_is_private_and_refuses_symlinks_or_terminal_bytes
    Dir.mktmpdir do |root|
      path = File.join(root, 'screen.png')
      png = "\x89PNG\r\n\x1a\nfixture".b
      value = {'png'=>Base64.strict_encode64(png), 'width'=>1024, 'height'=>768}
      output = StringIO.new
      MacControlCommands.screenshot(value, path:path, output:output)
      assert_equal png, File.binread(path)
      assert_equal 0600, File.stat(path).mode & 0777
      assert_equal path, JSON.parse(output.string)['path']
      File.symlink(path, File.join(root,'link.png'))
      assert_raises(MacControlCommands::Error) { MacControlCommands.screenshot(value, path:File.join(root,'link.png')) }
      tty = Object.new
      tty.define_singleton_method(:tty?) { true }
      assert_raises(MacControlCommands::Error) { MacControlCommands.screenshot(value, output:tty) }
      assert_raises(MacControlCommands::Error) { MacControlCommands.screenshot({'png'=>'bad'}, path:path) }
      assert_equal png, File.binread(path)
    end
  end
  def test_skill_install_is_offline_idempotent_and_preserves_user_edits
    Dir.mktmpdir do |root|
      GuestControlClient.stub(:request, ->(*) { raise 'Unexpected service contact' }) do
        2.times { capture_io { GuestControlClient.skill(['install'], root:File.expand_path('../guest', __dir__), home:root) } }
        path = File.join(root,'.agents/skills/mac-control/SKILL.md')
        original = File.read(path)
        File.write(path, 'user customization')
        assert_raises(MacControlCommands::Error) { GuestControlClient.skill(['install'], root:File.expand_path('../guest', __dir__), home:root) }
        assert_equal 'user customization', File.read(path)
        capture_io { GuestControlClient.skill(%w[install --force], root:File.expand_path('../guest', __dir__), home:root) }
        assert_equal original, File.read(path)
        assert_includes capture_io { GuestControlClient.main(%w[help drag]) }.first, '--duration'
      end
    end
  end
  def test_paste_uses_literal_stdin_and_only_delegates_cmd_v
    requests, command = [], nil
    ok = Struct.new(:success?).new(true)
    GuestControlClient.stub(:request, ->(value) { requests << value; {'ok'=>true} }) do
      Open3.stub(:capture3, ->(*args, **opts) { command = [args, opts]; [JSON.generate('ok'=>true),'',ok] }) do
        capture_io { GuestControlClient.paste(["{\\rtf1 literal} café\n"]) }
      end
    end
    assert_equal [{'op'=>'status'}, {'op'=>'key','key'=>'cmd+v'}], requests
    assert_equal 'write', command[0].last
    refute_includes command[0].join(' '), 'café'
    assert_equal "{\\rtf1 literal} café\n", JSON.parse(command[1][:stdin_data])['text']
  end
end
