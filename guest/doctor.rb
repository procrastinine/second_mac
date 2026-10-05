#!/usr/bin/ruby
require '/usr/local/libexec/agent-vm/core'
require '/usr/local/libexec/agent-vm/network-dns'

begin
  config = JSON.parse(File.read('/etc/agent-vm/config.json'))
  user = config.fetch('user')
  home = "/Users/#{user}"
  labels = [config.fetch('rpc_label', 'local.agent-vm.rpc'),
            config.fetch('shares_label', 'local.agent-vm.shares'), 'local.agent-vm.privacy']
  labels.each { |label| AgentVM.run('/bin/launchctl', 'print', "system/#{label}", capture:true) }
  puts 'Managed connection, sharing and privacy services: loaded'

  mounts = AgentVM.run('/sbin/mount', capture:true)
  if config['sharing'] == 'none'
    raise AgentVM::Error, 'Unexpected shared filesystem with sharing disabled.' if mounts.match?(/\((AppleVirtIOFS|virtiofs)[,) ]/)
    puts 'Shared filesystem: disabled'
  else
    AgentVM.share_entries(config).each do |entry|
      mount = '/Volumes/' + entry['name']
      line = mounts.lines.find { |row| row.include?(" on #{mount} (") && row.match?(/\((AppleVirtIOFS|virtiofs)[,) ]/) }
      raise AgentVM::Error, 'Shared filesystem is not mounted; ask your administrator to restore file sharing.' unless line
      raise AgentVM::Error, 'Shared filesystem should be read-only.' if entry['read_only'] && !line.include?('read-only')
      link = File.join(home, entry['name'])
      unless File.symlink?(link) && File.readlink(link) == mount
        raise AgentVM::Error, 'Shared-folder link is missing; ask your administrator to repair the configuration.'
      end
      puts "Shared filesystem: #{entry['name']} mounted#{entry['read_only'] ? ' read-only' : ''}"
    end
  end

  services = AgentVM.run('/usr/sbin/networksetup', '-listallnetworkservices', capture:true).lines.drop(1)
  services = services.map(&:strip).reject { |service| service.empty? || service.start_with?('*') }
  raise AgentVM::Error, 'No network service found.' if services.empty?
  automatic = MacNetworkDNS.automatic?
  services.each do |service|
    dns = AgentVM.run('/usr/sbin/networksetup', '-getdnsservers', service, capture:true).strip
    correct = automatic ? dns.start_with?("There aren't any DNS Servers set") : dns.split == %w[9.9.9.9 149.112.112.112]
    raise AgentVM::Error, 'DNS differs from the managed network configuration.' unless correct
  end
  puts "DNS configuration: #{automatic ? 'automatic' : 'Quad9'} (internet connectivity is not checked)"
  print AgentVM.run('/usr/bin/osascript', '-l', 'JavaScript',
                    File.join(home, '.local/share/agent-vm/privacy-status.js'), capture:true)
rescue AgentVM::Error, KeyError, JSON::ParserError, SystemCallError => error
  warn "Error: #{error.message}"
  exit 1
end
