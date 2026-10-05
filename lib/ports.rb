require_relative 'core'
module AgentVM
  class Ports
    def initialize(vm)
      @vm = vm
    end
    def entries
      File.file?(@vm.file('ports.json')) ? JSON.parse(File.read(@vm.file('ports.json'))) : []
    end
    def socket(entry)
      @vm.control_socket("port-#{entry['direction']}-#{entry['from']}")
    end
    def alive?(entry)
      return false unless File.socket?(socket(entry))
      AgentVM.run(*@vm.ssh_args, '-S', socket(entry), '-O', 'check', @vm.name, capture:true, timeout:5)
      true
    rescue Error
      false
    end
    def close(entry)
      return unless File.socket?(socket(entry))
      AgentVM.run(*@vm.ssh_args, '-S', socket(entry), '-O', 'exit', @vm.name, capture:true, timeout:5)
    rescue Error
      File.unlink(socket(entry)) if File.socket?(socket(entry))
    end
    def open(entry)
      return if alive?(entry)
      close(entry)
      flag = entry['direction'] == 'host' ? '-R' : '-L'
      # 'from' is the source service, 'to' is its loopback port on the other side.
      mapping = "127.0.0.1:#{entry['to']}:127.0.0.1:#{entry['from']}"
      args = [*@vm.ssh_args, '-M', '-S', socket(entry), '-fNT', '-o', 'ExitOnForwardFailure=yes',
              '-E', @vm.file('ports-ssh.log'), flag, mapping, @vm.name]
      # SSH and its ProxyCommand outlive this command. Give them their own
      # descriptors so a caller capturing `vm ports` receives EOF immediately.
      AgentVM.run('/bin/sh', '-c', 'umask 077; forward_log=$1; shift; exec "$@" </dev/null >/dev/null 2>>"$forward_log"',
                  'sh', @vm.file('ports-ssh.log'), *args, timeout:20)
    end
    def start_all
      with_lock { entries.each { |entry| open(entry) } }
    end
    def stop_all
      with_lock { entries.each { |entry| close(entry) } }
    end
    def with_lock
      File.open(@vm.file('ports.lock'), File::RDWR | File::CREAT, 0600) do |lock|
        raise Error, 'Another port operation is in progress; retry when it finishes.' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        yield
      end
    end
    def add(direction, source, destination = nil)
      with_lock { add_unlocked(direction, source, destination) }
    end
    def self.entry(direction, source, destination = nil)
      raise Error, 'Direction must be host or guest.' unless %w[host guest].include?(direction)
      ports = [source, destination || source].each_with_index.map do |value, index|
        range = index.zero? ? (1..65535) : (1024..65535)
        raise Error, 'Service ports must be 1–65535; the new listening port must be 1024–65535.' unless value.to_s.match?(/\A\d{1,5}\z/) && range.cover?(value.to_i)
        value.to_i
      end
      {'direction'=>direction, 'from'=>ports[0], 'to'=>ports[1]}
    end
    def add_unlocked(direction, source, destination)
      entry = self.class.entry(direction, source, destination)
      current = entries
      old = current.find { |e| e['direction'] == direction && e['from'] == entry['from'] }
      raise Error, 'This destination port is already forwarded.' if current.any? { |e| e != old && e['direction'] == direction && e['to'] == entry['to'] }
      return list if old == entry && alive?(old)
      close(old) if old
      begin
        open(entry)
        AgentVM.json_write(@vm.file('ports.json'), (current - [old]) + [entry])
      rescue StandardError
        close(entry)
        open(old) if old
        raise
      end
      list
    end
    def remove(direction, source)
      with_lock do
        current = entries
        found = current.find { |e| e['direction'] == direction && e['from'].to_s == source }
        raise Error, 'No such port forward.' unless found
        active = alive?(found)
        close(found)
        begin
          AgentVM.json_write(@vm.file('ports.json'), current - [found])
        rescue StandardError
          open(found) if active
          raise
        end
      end
    end
    def list
      if entries.empty?
        puts 'No ports exposed.'
      else
        entries.each do |e|
          accessible_on = e['direction'] == 'host' ? 'guest' : 'host'
          puts "#{e['direction']} localhost:#{e['from']} -> #{accessible_on} localhost:#{e['to']} (#{alive?(e) ? 'active' : 'stopped'})"
        end
      end
      puts 'Add: ports host HOST_PORT [GUEST_PORT] | ports guest GUEST_PORT [HOST_PORT]'
      puts 'Remove: ports remove host|guest SOURCE_PORT'
    end
  end
end
