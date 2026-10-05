require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/credentials'
require_relative '../guest/configure-relay'

class ModelRelayTest < Minitest::Test
  def setup
    @active, @key = true, 'host-key-fixture'
    @received = Queue.new
    @reply = ->(res) { res['Content-Type'] = 'application/json'; res.body = '{"ok":true}' }
    @upstream = WEBrick::HTTPServer.new(BindAddress:'127.0.0.1', Port:0, AccessLog:[], Logger:WEBrick::Log.new(File::NULL))
    @upstream.mount_proc('/') do |req, res|
      @received << [req.request_method, req.unparsed_uri, req.body, req['authorization'], req['x-test']]
      @reply.call(res)
    end
    @threads = [Thread.new { @upstream.start }]
    factory = -> { Net::HTTP.new('127.0.0.1', @upstream.listeners.first.addr[1], nil) }
    @api = AgentVM::ModelRelayAPI.new(token:'local-token', active:-> { @active }, key:-> { @key }, transport:factory)
    @server = @api.server
    @port = @server.listeners.first.addr[1]
    @threads << Thread.new { @server.start }
  end
  def teardown
    @api.close
    @server.shutdown; @upstream.shutdown
    @threads.each { |thread| thread.join(3) || thread.kill }
  end
  def request(body:'{"model":"a-model","provider":{"zdr":true}}', token:'local-token', path:'/v1/chat/completions', &block)
    req = Net::HTTP::Post.new(path, 'Authorization'=>'Bearer ' + token, 'Content-Type'=>'application/json', 'X-Test'=>'preserved')
    req.body = body
    client = Net::HTTP.new('127.0.0.1', @port, nil)
    client.read_timeout = 4
    client.request(req, &block)
  end
  def test_transparent_body_query_headers_and_rotatable_host_key
    body = "{ \"model\":\"future-model\", \"unrecognized_new_option\":true }\n"
    assert_equal '200', request(body:body, path:'/v1/chat/completions?example=1').code
    assert_equal ['POST', '/api/v1/chat/completions?example=1', body, 'Bearer host-key-fixture', 'preserved'], @received.pop
    @key = 'rotated-host-key'
    assert_equal '200', request(body:'not even parsed by this relay').code
    assert_equal 'Bearer rotated-host-key', @received.pop[3]
    assert_equal '127.0.0.1', @server.listeners.first.addr[3]
  end
  def test_guest_auth_revocation_and_fixed_origin
    assert_equal '401', request(token:'wrong').code
    assert_equal '404', request(path:'/https://another-provider.example/').code
    @active = false
    assert_equal '403', request.code
    assert @received.empty?
  end
  def test_sse_is_delivered_before_completion
    finish = Queue.new
    @reply = lambda do |res|
      res['Content-Type'] = 'text/event-stream'
      res.chunked = true
      res.body = proc do |out|
        out.write("data: first\n\n")
        Timeout.timeout(3) { finish.pop }
        out.write("data: [DONE]\n\n")
      end
    end
    chunks = ''
    request do |res|
      assert_equal '200', res.code
      res.read_body do |chunk|
        chunks << chunk
        finish << true if chunks.include?('first')
      end
    end
    assert_includes chunks, 'data: first'
    assert_includes chunks, 'data: [DONE]'
  end
  def test_provider_errors_and_redirects_are_not_retried_or_followed
    @reply = ->(res) { res.status = 429; res['Retry-After'] = '5'; res.body = 'quota' }
    result = request
    assert_equal ['429', '5', 'quota'], [result.code, result['retry-after'], result.body]
    @received.pop
    @reply = ->(res) { res.status = 307; res['Location'] = 'https://another-provider.example/'; res.body = 'redirect' }
    assert_equal '307', request.code
    @received.pop
    assert @received.empty?
  end
  def test_revocation_cancels_an_upstream_wait_without_waiting_for_its_timeout
    finish = Queue.new
    @reply = ->(res) { finish.pop; res.body = 'late' }
    client = Thread.new { request }
    Timeout.timeout(3) { @received.pop }
    @active = false
    @api.close
    assert_equal '502', Timeout.timeout(3) { client.value }.code
  ensure
    finish << true if finish
    client.kill if client && client.alive?
  end
  def test_bodyless_responses_do_not_leave_stream_workers
    @reply = ->(res) { res.status = 204 }
    assert_equal '204', request.code
    assert_empty @api.instance_variable_get(:@workers)
  end
end

class HostCredentialsTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('model-credentials-')
    @old = ENV['AGENT_VM_HOME']; ENV['AGENT_VM_HOME'] = @tmp
    @vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('share'=>File.join(@tmp, 'share')))
    @vm.save
    @vm.define_singleton_method(:running?) { false }
    @vm.define_singleton_method(:running_pid) { 0 }
    @credentials = AgentVM::Credentials.new(@vm)
  end
  def teardown
    ENV['AGENT_VM_HOME'] = @old
    FileUtils.remove_entry(@tmp)
  end
  def test_private_host_key_and_inspection_without_boot
    AgentVM::HostCredentials.prepare
    assert_equal 0600, File.stat(AgentVM::HostCredentials.path).mode & 0777
    assert_equal 0700, File.stat(File.dirname(AgentVM::HostCredentials.path)).mode & 0777
    refute AgentVM::HostCredentials.available?
    AgentVM.write(AgentVM::HostCredentials.path, "fixture-key\n")
    @credentials.set('on')
    assert @credentials.enabled?
    refute @credentials.active?
    assert_equal ['openrouter'], AgentVM::VM.load(@vm.name).config['credential_relays']
    refute AgentVM.guest_config(@vm.config).key?('credential_relays')
    AgentVM.json_write(@credentials.grant_path, {'token'=>'capability', 'guest_port'=>12345})
    @credentials.stub(:system, true) { @credentials.stop }
    assert File.file?(@credentials.grant_path), 'ordinary stops retain the client address/token'
    @credentials.stub(:system, true) { @credentials.set('off') }
    refute File.exist?(@credentials.grant_path), 'explicit revocation rotates the grant'
    assert @vm.config['credential_relay_cleanup'], 'stopped guest cleanup stays pending'
    assert_equal 'fixture-key', AgentVM::HostCredentials.read
  end
  def test_pi_setup_is_idempotent_and_removes_only_managed_values
    home = File.join(@tmp, 'guest')
    pi = File.join(home, '.pi/agent')
    AgentVM.json_write(File.join(pi, 'models.json'), {'providers'=>{'openrouter'=>{'compat'=>{'openRouterRouting'=>{'zdr'=>true, 'sort'=>'exacto'}}, 'apiKey'=>'old-key'}}})
    AgentVM.json_write(File.join(pi, 'auth.json'), {'openrouter'=>{'type'=>'api_key', 'key'=>'old-key'}, 'other'=>{'key'=>'unrelated'}})
    value = {'enabled'=>true, 'provider'=>'openrouter', 'base_url'=>'http://127.0.0.1:12345/v1', 'token'=>'local-token'}
    ModelRelayClient.configure(value.dup, home:home)
    first = File.stat(File.join(pi, 'auth.json')).mtime
    ModelRelayClient.configure(value.dup, home:home)
    assert_equal first, File.stat(File.join(pi, 'auth.json')).mtime
    models = ModelRelayClient.read(File.join(pi, 'models.json'))
    assert_equal true, models.dig('providers', 'openrouter', 'compat', 'openRouterRouting', 'zdr')
    assert_equal 'exacto', models.dig('providers', 'openrouter', 'compat', 'openRouterRouting', 'sort')
    refute models['providers']['openrouter'].key?('apiKey')
    refute_includes Dir.glob(home+'/**/*', File::FNM_DOTMATCH).select { |f| File.file?(f) }.map { |f| File.read(f) }.join, 'old-key'
    ModelRelayClient.configure({'enabled'=>false}, home:home)
    refute ModelRelayClient.read(File.join(pi, 'models.json'))['providers']['openrouter'].key?('baseUrl')
    assert_equal({'other'=>{'key'=>'unrelated'}}, ModelRelayClient.read(File.join(pi, 'auth.json')))
    refute File.exist?(File.join(home, '.config/second-mac/model-relay.json'))
  end
  def test_disabling_preserves_later_user_edits
    home = File.join(@tmp, 'guest')
    pi = File.join(home, '.pi/agent')
    FileUtils.mkdir_p(pi)
    ModelRelayClient.configure({'enabled'=>true, 'base_url'=>'http://127.0.0.1:12345/v1', 'token'=>'local-token'}, home:home)
    AgentVM.json_write(File.join(pi, 'models.json'), {'providers'=>{'openrouter'=>{'baseUrl'=>'https://user-chosen.example/v1'}}})
    AgentVM.json_write(File.join(pi, 'auth.json'), {'openrouter'=>{'type'=>'api_key', 'key'=>'user-chosen'}})
    ModelRelayClient.configure({'enabled'=>false}, home:home)
    assert_equal 'https://user-chosen.example/v1', ModelRelayClient.read(File.join(pi, 'models.json')).dig('providers', 'openrouter', 'baseUrl')
    assert_equal 'user-chosen', ModelRelayClient.read(File.join(pi, 'auth.json')).dig('openrouter', 'key')
  end
end
