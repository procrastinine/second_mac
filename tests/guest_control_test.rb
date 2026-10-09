require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require 'stringio'
require_relative '../lib/guest-control'
require_relative '../guest/control-client'

class GuestControlTest < Minitest::Test
  def setup
    @token, @active = SecureRandom.hex(32), true
    @api = AgentVM::GuestControlAPI.new(Object.new, @token, -> { @active })
    @server = @api.server
    @port = @server.listeners.first.addr[1]
    started = Queue.new
    @server.config[:StartCallback] = -> { started << true }
    @thread = Thread.new { @server.start }
    Timeout.timeout(5) { started.pop }
  end
  def teardown
    @server.shutdown
    @thread.join
  end
  def request(value = {'op'=>'status'}, headers:{}, token:@token)
    client = Net::HTTP.new('127.0.0.1', @port, nil)
    client.read_timeout = 3
    req = Net::HTTP::Post.new('/v1/control', {'Content-Type'=>'application/json', 'Authorization'=>'Bearer ' + token}.merge(headers))
    req.body = JSON.generate(value)
    client.request(req)
  end
  def test_loopback_authentication_revocation_and_no_cors
    assert_equal '127.0.0.1', @server.listeners.first.addr[3]
    assert_equal '401', request(token:'bad').code
    assert_equal '200', request.code
    assert_nil request['Access-Control-Allow-Origin']
    assert_equal '403', request(headers:{'Origin'=>'https://example.com'}).code
    assert_equal '403', request(headers:{'Sec-Fetch-Site'=>'same-origin'}).code
    @active = false
    assert_equal '403', request.code
  end
  def test_host_and_lifecycle_operations_are_rejected_even_with_correct_token
    %w[sip reboot shutdown exec shell ports shares network-set network-status enable disable show hide auto camera microphone clipboard clipboard-read clipboard-write to-guest to-host].each do |op|
      assert_equal '403', request({'op'=>op}).code, op
    end
    assert_equal '400', request({'op'=>'status', 'vm'=>'another-guest'}).code
    assert_equal '400', request({'op'=>'click', 'x'=>'1;command', 'y'=>0}).code
    assert_equal '413', request({'op'=>'type', 'text'=>'x' * 20000}).code
    assert_equal '400', request({'op'=>'type', 'text'=>"x\x00y"}).code
  end
  def test_timed_key_requests_are_validated_before_dispatch
    desktop, calls = Object.new, []
    desktop.define_singleton_method(:keyboard) { |key, hold_ms:nil| calls << [key,hold_ms] }
    @api.instance_variable_set(:@desktop, desktop)
    assert_equal '200', request({'op'=>'key','key'=>'a'}).code
    assert_equal '200', request({'op'=>'key','key'=>'cmd+shift+a','hold_ms'=>500}).code
    assert_equal [['a',nil],['cmd+shift+a',500]], calls
    [nil, true, '80', 0, 9, 5001, 50.5].each do |bad|
      assert_equal '400', request({'op'=>'key','key'=>'a','hold_ms'=>bad}).code
    end
    assert_equal '400', request({'op'=>'key','key'=>'a','hold_ms'=>80,'phase'=>'down'}).code
    assert_equal '403', request({'op'=>'key-down','key'=>'a'}).code
    assert_equal 2, calls.length
    desktop.define_singleton_method(:keyboard) { |*_, **_| raise AgentVM::Desktop::UnsupportedInput, 'The running viewer needs an update and a later VM restart for timed key holds.' }
    response = request({'op'=>'key','key'=>'a','hold_ms'=>80})
    assert_equal '422', response.code
    assert_includes response.body, 'later VM restart'
  end
  def test_approved_operations_reach_only_the_bound_guest
    desktop = Object.new
    desktop.define_singleton_method(:approve_once) { true }
    @api.instance_variable_set(:@desktop, desktop)
    assert_equal({'approved'=>true}, JSON.parse(request({'op'=>'approve'}).body))
    calls = []
    permissions = Object.new
    permissions.define_singleton_method(:direct) { |args, **options| calls << [args, options]; 'Recorded allow.' }
    permissions.define_singleton_method(:change) { |action, app, names| calls << [action, app, names]; 'Allowed in guest Settings.' }
    @api.instance_variable_set(:@permissions, permissions)
    value = {'op'=>'grant', 'app'=>"/Applications/An App.app", 'permissions'=>['documents']}
    assert_equal '200', request(value).code
    assert_equal [['grant','/Applications/An App.app',['documents']]], calls
    assert_equal '400', request(value.merge('permissions'=>['all','documents'])).code
    assert_equal '400', request(value.merge('permissions'=>['--disable-sip'])).code
    assert_equal '400', request(value.merge('app'=>'relative.app')).code
    assert_equal 1, calls.length
    assert_equal '400', request({'op'=>'extension','kind'=>'kernel','app'=>'macFUSE'}).code
    assert_equal '200', request(value.merge('op'=>'check')).code
  end
  def test_pointer_and_text_api_validates_scope_and_reaches_bound_desktop
    desktop, calls = Object.new, []
    desktop.define_singleton_method(:pointer) { |value| calls << value; {'ok'=>true} }
    desktop.define_singleton_method(:type) { |value| calls << value }
    @api.instance_variable_set(:@desktop, desktop)
    %w[move drag scroll].zip([%w[move 10 20], %w[drag 10 20 100 200], %w[scroll down]]).each do |_,args|
      assert_equal '200', request(GuestControlClient.payload(args)).code
    end
    assert_equal '200', request({'op'=>'type','text'=>"hello\tworld\n"}).code
    assert_equal "hello\tworld\n", calls.last
    before = calls.length
    assert_equal '400', request({'op'=>'drag','x'=>0,'y'=>0,'to_x'=>9999,'to_y'=>0,'duration'=>1}).code
    assert_equal '400', request({'op'=>'scroll','x'=>0,'y'=>0,'dx'=>0,'dy'=>100,'host'=>true}).code
    assert_equal '400', request({'op'=>'type','text'=>'café'}).code
    assert_equal before, calls.length
  end
  def test_server_errors_do_not_disclose_host_paths_or_arguments
    desktop = Object.new
    desktop.define_singleton_method(:approve_once) { raise AgentVM::Error, '/private/host-secret and subprocess arguments' }
    @api.instance_variable_set(:@desktop, desktop)
    response = request({'op'=>'approve'})
    assert_equal '422', response.code
    refute_includes response.body, 'host-secret'
    refute_includes response.body, 'arguments'
  end
  def test_parallel_guest_actions_fail_busy_without_queueing
    mutex = @api.instance_variable_get(:@busy)
    mutex.lock
    assert_equal '409', request({'op'=>'approve'}).code
    assert_equal '200', request.code
    mutex.unlock
    assert_equal '200', request.code
  end
  def test_client_uses_loopback_and_private_config_and_rejects_old_token
    Dir.mktmpdir('guest-control-') do |dir|
      path = File.join(dir, 'config.json')
      AgentVM.json_write(path, {'port'=>@port, 'token'=>@token})
      assert GuestControlClient.request({'op'=>'status'}, path:path)['enabled']
      File.chmod(0644, path)
      assert_raises(GuestControlClient::Error) { GuestControlClient.request({'op'=>'status'}, path:path) }
      AgentVM.json_write(path, {'port'=>@port, 'token'=>SecureRandom.hex(32)})
      error = assert_raises(GuestControlClient::Error) { GuestControlClient.request({'op'=>'status'}, path:path) }
    assert_equal 'Invalid Mac control token.', error.message
    end
    assert_equal({'op'=>'type', 'text'=>'hello'}, GuestControlClient.payload(['type'], input:StringIO.new('hello')))
    assert_raises(GuestControlClient::Error) { GuestControlClient.payload(['type'], input:StringIO.new('x' * 4097)) }
    assert_raises(GuestControlClient::Error) { GuestControlClient.payload(['sip', 'off']) }
  end
  def test_generation_must_match_current_vm_process_and_host_mode
    Dir.mktmpdir('control-state-') do |dir|
      vm = Object.new
      vm.define_singleton_method(:file) { |name| File.join(dir, name) }
      vm.define_singleton_method(:running_pid) { 123 }
      vm.define_singleton_method(:ui_available?) { true }
      control = AgentVM::GuestControl.new(vm)
      AgentVM.json_write(vm.file('config.json'), {'guest_control'=>true})
      AgentVM.json_write(vm.file('guest-control.json'), {'generation'=>'current'})
      assert control.generation_active?(123, 'current')
      refute control.generation_active?(456, 'current')
      refute control.generation_active?(123, 'stale')
      AgentVM.json_write(vm.file('config.json'), {'guest_control'=>false})
      refute control.generation_active?(123, 'current')
    end
  end
  def test_service_retry_exits_cleanly_after_vm_exit_or_revocation
    Dir.mktmpdir('control-exit-') do |directory|
      vm = Object.new
      vm.define_singleton_method(:running_pid) { 456 }
      vm.define_singleton_method(:file) { |name| File.join(directory, name) }
      control = AgentVM::GuestControl.new(vm)
      control.stub(:enabled?, false) { assert_nil control.serve('123') }
      control.stub(:enabled?, true) { assert_nil control.serve('123') }
      assert_raises(AgentVM::Error) { control.serve('0') }
    end
  end
  def test_guest_help_and_local_password_use_mac_control_without_host_delegation
    output, = capture_io { GuestControlClient.main(['help']) }
    assert_includes output, 'mac-control grant'
    assert_includes output, 'mac-control password'
    refute_includes output, 'vm-control'
    called = nil
    GuestControlClient.stub(:password, ->(args) { called = args }) do
      GuestControlClient.main(%w[password --local])
    end
    assert_equal ['--local'], called
    assert_raises(GuestControlClient::Error) { GuestControlClient.main(%w[camera on]) }
  end
  def test_autostart_manual_grants_and_stop_are_scoped_to_one_vm_and_boot
    Dir.mktmpdir('control-lifetime-') do |directory|
      config = {'ui_enabled'=>true, 'guest_control'=>false}
      owner = 123
      vm = Object.new
      vm.define_singleton_method(:config) { config }
      vm.define_singleton_method(:ui_available?) { true }
      vm.define_singleton_method(:file) { |name| File.join(directory, name) }
      vm.define_singleton_method(:running_pid) { owner }
      vm.define_singleton_method(:running?) { owner > 0 }
      vm.define_singleton_method(:save) { AgentVM.json_write(vm.file('config.json'), config) }
      vm.define_singleton_method(:domain) { 'gui/999999' }
      vm.define_singleton_method(:name) { 'test-copy' }
      vm.save
      control = AgentVM::GuestControl.new(vm)
      control.stub(:start, nil) do
        capture_io { control.command(%w[on --once]) }
        assert control.enabled?
        refute config['guest_control']
        owner = 456
        refute control.enabled?, 'one-boot grant must not authorize a different VM process'
        owner = 123
        control.stub(:system, true) { control.stop }
        refute control.enabled?
        refute File.exist?(control.session_path)
        capture_io { control.command(%w[autostart on]) }
        assert config['guest_control']
        refute control.enabled?, 'changing future startup must not enable this run'
        owner = 456
        assert control.enabled?
        capture_io { control.command(%w[autostart off]) }
        refute config['guest_control']
        assert control.enabled?, 'turning off future starts retains the current grant until shutdown'
        control.stub(:system, true) { control.stop }
        refute control.enabled?
      end
    end
  end
end
