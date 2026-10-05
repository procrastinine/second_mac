require 'socket'
require 'json'
require 'timeout'
require 'ipaddr'

module AgentVM
  # Tart already hands Softnet an Ethernet socket. Keep that descriptor open
  # across helper changes and give it directly to the active child. This
  # supervisor never reads, copies or forwards a packet, including native mode.
  class NetworkSupervisor
    NATIVE = '/opt/homebrew/bin/softnet'.freeze
    def initialize(args, environment:ENV)
      @environment = environment
      @owner = Process.ppid
      @path = environment.fetch('SECOND_MAC_NETWORK_SOCKET')
      @backend = environment.fetch('SECOND_MAC_NETWORK_BACKEND')
      @binary = @backend == 'native' ? NATIVE : environment.fetch('SECOND_MAC_NETWORK_BINARY')
      raise 'Invalid network backend.' unless %w[native vpn].include?(@backend)
      raise 'Invalid network arguments.' unless args.length.even? && args.each_slice(2).all? { |key, _| %w[--vm-fd --vm-mac-address --allow --block].include?(key) }
      options = args.each_slice(2).to_h
      raise 'Repeated network arguments.' unless options.length * 2 == args.length
      raise 'Expected Tart Ethernet descriptor.' unless options['--vm-fd'] == '0'
      @mac = options.fetch('--vm-mac-address')
      raise 'Invalid virtual MAC address.' unless @mac.match?(/\A(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\z/i)
      raise 'Invalid bootstrap rule.' unless [nil, 'in @host'].include?(options['--allow'])
      @arguments = args
      @bootstrap = options['--allow'] == 'in @host'
      validate_blocks(options.fetch('--block'))
      @wire = Socket.for_fd(0)
      @wire.autoclose = false
      raise 'Expected a datagram socket.' unless @wire.getsockopt(Socket::SOL_SOCKET, Socket::SO_TYPE).int == Socket::SOCK_DGRAM
    end

    def validate_blocks(value)
      raise 'Invalid network restrictions.' unless value.is_a?(String) && value.bytesize.between?(1, 8192)
      value.split(',').each do |block|
        next if ['@host', 'out @host'].include?(block)
        raise 'Only IPv4 restrictions are supported.' unless IPAddr.new(block).ipv4?
      end
    end

    def open_control
      directory = File.lstat(File.dirname(@path))
      raise 'Unsafe network control directory.' unless directory.directory? && directory.uid == Process.uid && (directory.mode & 0077).zero?
      @lock = File.open(@path + '.lock', File::RDWR|File::CREAT, 0600)
      raise 'Network controller already running.' unless @lock.flock(File::LOCK_EX|File::LOCK_NB)
      if File.exist?(@path) || File.symlink?(@path)
        metadata = File.lstat(@path)
        raise 'Unsafe network control socket.' unless metadata.socket? && metadata.uid == Process.uid
        File.unlink(@path)
      end
      @server = UNIXServer.new(@path)
      File.chmod(0600, @path)
    end

    def alive?
      return false unless @child
      return true unless Process.waitpid(@child, Process::WNOHANG)
      @child = nil
      false
    rescue Errno::ECHILD
      @child = nil
      false
    end

    def start_child
      raise 'Network helper is missing.' unless @binary.start_with?('/') && File.executable?(@binary)
      environment = {'SECOND_MAC_BOOTSTRAP_PORT'=>@bootstrap ? @environment['SECOND_MAC_BOOTSTRAP_PORT'] : nil}
      # Keep only fd 0 as the child's network endpoint. In particular the
      # private listener/lock never reach Softnet or the VPN router.
      @child = Process.spawn(environment, @binary, *@arguments, in:@wire, close_others:true)
      sleep 0.2
      raise 'Network helper exited; guest internet remains disconnected.' unless alive?
    end

    def stop_child
      return unless alive?
      Process.kill('INT', @child)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      sleep 0.05 while alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      if alive?
        Process.kill('KILL', @child)
        Process.waitpid(@child)
        @child = nil
      end
    rescue Errno::ESRCH, Errno::ECHILD
      @child = nil
    end

    def status
      healthy = alive?
      {'pid'=>@owner, 'supervisor_pid'=>Process.pid, 'helper_pid'=>@child,
       'backend'=>@backend, 'binary'=>@binary, 'blocks'=>@arguments.each_slice(2).to_h.fetch('--block'),
       'live_switch'=>true, 'healthy'=>healthy}
    end

    def dispatch(value)
      raise 'Invalid network command.' unless value.is_a?(Hash)
      return status if value == {'op'=>'network-status'}
      raise 'Invalid network command.' unless value.keys.sort == %w[backend binary blocks op] && value['op'] == 'network-set'
      backend, binary = value.values_at('backend', 'binary')
      raise 'Invalid network backend.' unless %w[native vpn].include?(backend)
      raise 'Invalid network helper.' unless binary.is_a?(String) && binary.start_with?('/') && File.executable?(binary)
      raise 'Invalid native network helper.' if backend == 'native' && binary != NATIVE
      validate_blocks(value['blocks'])
      stop_child # Never let two helpers read the Ethernet descriptor at once.
      @backend, @binary, @bootstrap = backend, binary, false
      @arguments = ['--vm-fd', '0', '--vm-mac-address', @mac, '--block', value['blocks']]
      start_child
      status
    end

    def serve(client)
      raise 'Network control requires the host owner.' unless client.getpeereid.first == Process.uid
      Timeout.timeout(10) do
        line = client.gets(16385)
        raise 'Invalid network request.' unless line && line.end_with?("\n") && line.bytesize <= 16384
        begin
          reply = dispatch(JSON.parse(line))
        rescue StandardError => error
          reply = {'error'=>error.message}
        end
        client.write(JSON.generate(reply) + "\n")
      end
    rescue StandardError => error
      warn "Network control: #{error.message}"
    ensure
      client.close
    end

    def run
      previous = %w[INT TERM HUP].to_h { |signal| [signal, Signal.trap(signal) { @stopping = true }] }
      open_control
      start_child
      until @stopping || Process.ppid != @owner
        alive?
        # A child failure leaves the VM/SSH alive with no internet. The host
        # route watcher can retry; never silently fall back to native egress.
        serve(@server.accept) if IO.select([@server], nil, nil, 1)
      end
    ensure
      stop_child
      if @server
        @server.close
        File.unlink(@path) if File.socket?(@path)
      end
      @lock.close if @lock
      previous.each { |signal, handler| Signal.trap(signal, handler) } if previous
    end
  end
end
