require_relative 'core'
require 'net/http'
require 'webrick'

module AgentVM
  # A fixed-origin credential relay. Bodies and provider options pass through
  # unchanged; this is not a prompt filter or a spending-policy engine.
  class ModelRelayAPI
    HOP_HEADERS = %w[connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade].freeze
    def initialize(token:, active:, key:, transport: nil)
      @token, @active, @key = token, active, key
      @workers, @worker_lock, @closed = {}, Mutex.new, false
      @transport = transport || lambda do
        Net::HTTP.new('openrouter.ai', 443, nil).tap do |client|
          client.use_ssl = true
          client.open_timeout = 20
          client.read_timeout = 600
          client.write_timeout = 60 if client.respond_to?(:write_timeout=)
          client.max_retries = 0 # Do not silently repeat a billed request.
        end
      end
    end
    def authorized?(value)
      expected = 'Bearer ' + @token
      value && value.bytesize == expected.bytesize &&
        value.bytes.zip(expected.bytes).reduce(0) { |diff, (a,b)| diff | (a ^ b) }.zero?
    end
    def error(res, status, message)
      res.status, res['Content-Type'] = status, 'application/json'
      res.body = JSON.generate('error'=>{'message'=>message})
    end
    def handle(req, res)
      # Reading before rejecting avoids an unread-body TCP reset swallowing the
      # response. No JSON parsing, model validation or rewriting is involved.
      body = req.body
      res.keep_alive = false
      res['Cache-Control'], res['Connection'] = 'no-store', 'close'
      return error(res, 403, 'Model relay is disabled.') unless @active.call
      return error(res, 401, 'Invalid model relay credential.') unless authorized?(req['authorization'])
      if req.request_method == 'GET' && req.unparsed_uri == '/health'
        res['Content-Type'], res.body = 'application/json', '{"provider":"openrouter","enabled":true}'
        return
      end
      return error(res, 404, 'Use the OpenRouter /v1/ API.') unless req.unparsed_uri.start_with?('/v1/')
      headers = {}
      skip = HOP_HEADERS + req['connection'].to_s.downcase.split(/\s*,\s*/) + %w[host authorization content-length accept-encoding cookie]
      req.each { |name, value| headers[name] = value unless skip.include?(name.downcase) }
      headers['Authorization'], headers['Accept-Encoding'] = 'Bearer ' + @key.call, 'identity'
      upstream = Net::HTTPGenericRequest.new(req.request_method, !body.nil?, req.request_method != 'HEAD', '/api' + req.unparsed_uri, headers)
      upstream.body = body if body
      relay(upstream, res)
    rescue StandardError
      error(res, 502, 'Model relay could not reach the provider. Check the host key and connection.')
    end
    def relay(upstream, res)
      queue = SizedQueue.new(4)
      worker = Thread.new do
        Thread.current.report_on_exception = false
        begin
          @transport.call.start do |client|
            client.request(upstream) do |response|
              queue << [:headers, response]
              response.read_body { |chunk| queue << [:data, chunk] }
            end
          end
          queue << [:done]
        rescue StandardError
          queue << [:error]
        end
      end
      @worker_lock.synchronize do
        raise IOError, 'Model relay stopped' if @closed
        @workers[worker] = queue
      end
      message = Timeout.timeout(620) { queue.pop }
      raise IOError unless message.first == :headers
      response = message.last
      res.status = response.code.to_i
      skip = HOP_HEADERS + response['connection'].to_s.downcase.split(/\s*,\s*/) + %w[content-length set-cookie server]
      response.each_header { |name, value| res[name] = value unless skip.include?(name.downcase) }
      # Net::HTTP does not follow redirects. Never send the host key to one.
      return res.body = '' unless upstream.response_body_permitted? && ![204, 304].include?(res.status)
      res.chunked = true
      res.body = proc do |output|
        begin
          loop do
            raise IOError, 'Model relay disabled' unless @active.call
            part = Timeout.timeout(620) { queue.pop }
            break if part.first == :done
            raise IOError, 'Model stream interrupted' unless part.first == :data
            Timeout.timeout(60) { output.write(part.last) }
          end
        ensure
          worker.kill; worker.join
          @worker_lock.synchronize { @workers.delete(worker) }
        end
      end
      streaming = true
    ensure
      unless streaming
        worker.kill if worker
        worker.join if worker
        @worker_lock.synchronize { @workers.delete(worker) }
      end
    end
    def close
      workers = @worker_lock.synchronize { @closed = true; @workers.dup }
      workers.each do |worker, queue|
        worker.kill; worker.join
        queue.clear
        queue << [:error]
      end
    end
    def server
      WEBrick::HTTPServer.new(BindAddress:'127.0.0.1', Port:0, MaxClients:16,
        RequestTimeout:60, DoNotReverseLookup:true, AccessLog:[], ServerSoftware:'Model Relay',
        Logger:WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL)).tap do |server|
        # A servlet, rather than mount_proc, also handles DELETE/PATCH/OPTIONS.
        handler = Class.new(WEBrick::HTTPServlet::AbstractServlet) do
          def initialize(server, api); super(server); @api = api; end
          def service(req, res); @api.handle(req, res); end
        end
        server.mount('/', handler, self)
      end
    end
  end
end
