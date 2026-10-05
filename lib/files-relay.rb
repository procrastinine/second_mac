#!/usr/bin/ruby
require_relative 'core'
require 'socket'

module AgentVM
  # An authenticated SMB session over Tart's private guest channel. The only TCP
  # listener is host loopback; no guest network port or host LAN grant is added.
  class FilesRelay
    def initialize(vm, owner, generation)
      raise Error, 'Invalid relay generation.' unless generation.match?(/\A[0-9a-f]{32}\z/)
      @vm, @owner, @generation = vm, Integer(owner), generation
      raise Error, 'VM is not running.' unless @owner > 0
      @children = []
      @tag = 'second_mac_files_' + generation
    end

    def reap
      @children.delete_if { |pid| Process.waitpid(pid, Process::WNOHANG) rescue true }
    end

    def run
      raise Error, 'VM stopped before file access started.' unless @vm.running_pid == @owner
      @server = TCPServer.new('127.0.0.1', 0)
      @stopped = false
      %w[TERM INT].each { |signal| Signal.trap(signal) { @stopped = true } }
      AgentVM.json_write(@vm.file('files-relay.json'), {
        'generation'=>@generation, 'owner'=>@owner, 'pid'=>Process.pid, 'port'=>@server.addr[1]
      })
      until @stopped || @vm.running_pid != @owner
        reap
        next unless IO.select([@server], nil, nil, 0.5)
        client = @server.accept_nonblock(exception:false)
        next if client == :wait_readable
        begin
          next if @children.length >= 64
          client.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
          @children << Process.spawn(@vm.tart, 'exec', '-i', @vm.name,
            '/opt/homebrew/bin/socat', '-lp' + @tag, 'STDIO', 'TCP4:127.0.0.1:445',
            in:client, out:client, err:$stderr, pgroup:true)
        ensure
          client.close
        end
      end
    ensure
      close
    end

    def close
      @server.close if @server && !@server.closed?
      reap
      @children.each { |pid| Process.kill('TERM', -pid) rescue nil }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      while !@children.empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.05
        reap
      end
      @children.each { |pid| Process.kill('KILL', -pid) rescue nil }
      @children.each { |pid| Process.waitpid(pid) rescue nil }
      # RPC commands can outlive their host stdin. Reap only this generation's
      # guest relays, while the original VM process still owns the image.
      if @vm.running_pid == @owner
        begin
          AgentVM.run(@vm.tart, 'exec', @vm.name, '/usr/bin/pkill', '-f',
                      '^/opt/homebrew/bin/socat -lp' + @tag + ' ', capture:true, timeout:8)
        rescue Error
        end
      end
      path = @vm.file('files-relay.json')
      File.unlink(path) if File.file?(path) && JSON.parse(File.read(path))['generation'] == @generation
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    state, owner, generation = ARGV
    vm = AgentVM::VM.new(JSON.parse(File.read(File.join(state, 'config.json'))))
    raise AgentVM::Error, 'Relay state does not match the managed VM.' unless vm.state == state
    AgentVM::FilesRelay.new(vm, owner, generation).run
  rescue StandardError => error
    warn "File transport stopped: #{error.class}: #{error.message}"
    exit 1
  end
end
