#!/usr/bin/ruby
require_relative 'core'
vm = AgentVM::VM.new(JSON.parse(File.read(ARGV.fetch(0))))
unless File.socket?(vm.rpc_socket)
  warn 'VM transport is still starting; run vm start first.'
  exit 1
end
tag = "agent_vm_ssh_#{SecureRandom.hex(16)}"
relay = '/opt/homebrew/bin/socat'
child = nil
%w[TERM HUP INT].each { |sig| Signal.trap(sig) { exit 0 } }
begin
  child = Process.spawn(vm.tart, 'exec', '-i', vm.name, relay, "-lp#{tag}", 'STDIO', 'TCP4:127.0.0.1:22', pgroup: true)
  _, status = Process.wait2(child)
  exit(status.exitstatus || 1)
ensure
  %w[TERM HUP INT].each { |sig| Signal.trap(sig, 'IGNORE') }
  # Tart's RPC exec stream can outlive stdin. Reap only this connection's relay.
  cleaner = Process.spawn(vm.tart, 'exec', vm.name, '/usr/bin/pkill', '-f',
                          "^#{Regexp.escape(relay)} -lp#{tag} ", in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true)
  begin
    Timeout.timeout(5) { Process.wait(cleaner) }
  rescue Timeout::Error
    Process.kill('KILL', -cleaner) rescue nil
    Process.wait(cleaner) rescue nil
  end
  if child
    Process.kill('TERM', -child) rescue nil
    begin
      Timeout.timeout(2) { Process.wait(child) }
    rescue Timeout::Error
      Process.kill('KILL', -child) rescue nil
      Process.wait(child) rescue nil
    rescue Errno::ECHILD
    end
  end
end
