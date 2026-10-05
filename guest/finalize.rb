#!/usr/bin/ruby
require_relative '../lib/core'
require 'etc'
base = File.expand_path(__dir__)
config = JSON.parse(File.read(File.join(base, 'config.json')))
user, name = config.values_at('user', 'name')
home = "/Users/#{user}"
account = Etc.getpwnam(user)
raise 'Must run as root' unless Process.uid.zero?
AgentVM.validate(config)
AgentVM.run('/usr/bin/ruby', File.join(base, 'privacy.rb'), user)
%w[/usr/local/bin /usr/local/libexec/agent-vm /etc/agent-vm /etc/ssh/sshd_config.d /etc/sudoers.d].each { |p| FileUtils.mkdir_p(p) }
FileUtils.install(File.join(base, 'tart-guest-agent'), '/usr/local/bin/tart-guest-agent', mode: 0755)
%w[core.rb profile-plan.rb].each do |file|
  FileUtils.install(File.join(base, '..', 'lib', file), '/usr/local/libexec/agent-vm/' + file, mode: 0644)
end
FileUtils.install(File.join(base, 'mount-share.rb'), '/usr/local/libexec/agent-vm/mount-share.rb', mode: 0755)
FileUtils.install(File.join(base, 'network-dns.rb'), '/usr/local/libexec/agent-vm/network-dns.rb', mode: 0644)
# Remember names before replacing configuration, including installations from
# before the mount manifest existed. The mount helper removes only owned links.
manifest = '/etc/agent-vm/mounted-shares.json'
previous = File.file?(manifest) ? JSON.parse(File.read(manifest)) : []
if File.file?('/etc/agent-vm/config.json')
  old_config = JSON.parse(File.read('/etc/agent-vm/config.json'))
  %w[guest_share guest_read_only_share guest_linked_share].each { |key| previous << old_config[key] if old_config[key] }
end
AgentVM.json_write(manifest, previous.uniq)
AgentVM.json_write('/etc/agent-vm/config.json', config)
File.chmod(0644, '/etc/agent-vm/config.json')
File.unlink('/etc/agent-vm/shares.json') if File.file?('/etc/agent-vm/shares.json')
# Remove the old raw-path mount helper after installing its replacement.
File.unlink('/usr/local/libexec/mount-tart-shares.rb') if File.file?('/usr/local/libexec/mount-tart-shares.rb')
logs = File.join(home, 'Library/Logs')
FileUtils.mkdir_p(logs)
File.chown(account.uid, account.gid, logs)
tool_path = "#{home}/tools/python/bin:#{home}/.local/bin:#{home}/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/opt/openjdk/bin:/opt/homebrew/opt/sqlite/bin:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/bin:/opt/homebrew/sbin:/Library/TeX/texbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
rpc_label = config.fetch('rpc_label', 'local.agent-vm.rpc')
shares_label = config.fetch('shares_label', 'local.agent-vm.shares')
[rpc_label, shares_label].each { |label| raise 'Invalid service label' unless label.match?(/\Alocal\.[a-zA-Z0-9.-]+\z/) }
AgentVM.write("/Library/LaunchDaemons/#{rpc_label}.plist", AgentVM.plist({
  'Label' => rpc_label,
  'ProgramArguments' => ['/usr/local/bin/tart-guest-agent', '--run-rpc'],
  'UserName' => user, 'WorkingDirectory' => home,
  'EnvironmentVariables' => {
    'HOME' => home, 'PATH' => tool_path, 'LANG' => 'en_US.UTF-8', 'MPLBACKEND' => 'Agg',
    'DYLD_FALLBACK_LIBRARY_PATH' => '/opt/homebrew/lib', 'HOMEBREW_NO_ANALYTICS' => '1',
    'JAVA_HOME' => '/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home',
    'PLAYWRIGHT_MCP_CONFIG' => "#{home}/.config/playwright-brave.json",
    'DO_NOT_TRACK' => '1', 'OTEL_SDK_DISABLED' => 'true', 'HF_HUB_DISABLE_TELEMETRY' => '1'
  },
  'RunAtLoad' => true, 'KeepAlive' => true,
  'StandardOutPath' => "#{logs}/agent-vm-rpc.log", 'StandardErrorPath' => "#{logs}/agent-vm-rpc.log"
}), 0644)
system('/bin/launchctl', 'bootout', "system/#{shares_label}", out:File::NULL, err:File::NULL)
AgentVM.write("/Library/LaunchDaemons/#{shares_label}.plist", AgentVM.plist({
  'Label'=>shares_label,
  'ProgramArguments'=>['/usr/bin/ruby', '/usr/local/libexec/agent-vm/mount-share.rb'],
  'RunAtLoad'=>true, 'StartInterval'=>15,
  'StandardOutPath'=>"#{logs}/agent-vm-share.log", 'StandardErrorPath'=>"#{logs}/agent-vm-share.log"
}), 0644)
AgentVM.run('/bin/launchctl', 'bootstrap', 'system', "/Library/LaunchDaemons/#{shares_label}.plist")
# On a fresh VM start RPC before SSH becomes loopback-only. On updates the
# already-running agent stays alive until the final clean restart.
unless system('/bin/launchctl', 'print', "system/#{rpc_label}", out: File::NULL, err: File::NULL)
  AgentVM.run('/bin/launchctl', 'bootstrap', 'system', "/Library/LaunchDaemons/#{rpc_label}.plist")
end
AgentVM.write('/etc/ssh/sshd_config.d/010-agent-vm.conf', <<~SSHD, 0644)
  ClientAliveInterval 0
  TCPKeepAlive no
  ChannelTimeout none
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  PermitRootLogin no
  AllowAgentForwarding no
  AllowTcpForwarding yes
  GatewayPorts no
  PermitOpen 127.0.0.1:*
  PermitListen 127.0.0.1:*
  X11Forwarding no
  AllowUsers #{user}@127.0.0.1 #{user}@::1
SSHD
# Retire the original per-VM policy only when it is exactly our old policy.
# Preserve any file the owner has customized instead of guessing ownership.
legacy = "/etc/ssh/sshd_config.d/010-#{name}.conf"
legacy_policy = [
  'ClientAliveInterval 0', 'TCPKeepAlive no', 'ChannelTimeout none',
  'PasswordAuthentication no', 'KbdInteractiveAuthentication no',
  'PermitRootLogin no', 'AllowAgentForwarding no', 'X11Forwarding no',
  "AllowUsers #{user}@127.0.0.1 #{user}@::1"
]
if legacy != '/etc/ssh/sshd_config.d/010-agent-vm.conf' && File.file?(legacy)
  File.unlink(legacy) if File.readlines(legacy).map(&:strip).reject(&:empty?) == legacy_policy
end
AgentVM.run('/usr/sbin/sshd', '-t')
AgentVM.write('/etc/sudoers.d/agent-vm-lifecycle', "#{user} ALL=(root) NOPASSWD: /sbin/shutdown -h now\n", 0440)
AgentVM.run('/usr/sbin/visudo', '-cf', '/etc/sudoers.d/agent-vm-lifecycle')
AgentVM.run('/usr/bin/pmset', '-a', 'sleep', '0', 'displaysleep', '0')
AgentVM.run('/usr/sbin/scutil', '--set', 'ComputerName', name)
AgentVM.run('/usr/sbin/scutil', '--set', 'LocalHostName', name)
AgentVM.run('/usr/sbin/scutil', '--set', 'HostName', name)
services = AgentVM.run('/usr/sbin/networksetup', '-listallnetworkservices', capture: true).lines.drop(1).map(&:strip).reject { |s| s.empty? || s.start_with?('*') }
raise 'No active network services' if services.empty?
services.each do |service|
  AgentVM.run('/usr/sbin/networksetup', '-setv6off', service)
end
require_relative 'network-dns'
MacNetworkDNS.apply
AgentVM.run('/usr/sbin/systemsetup', '-settimezone', config.fetch('timezone'))
AgentVM.run('/usr/sbin/systemsetup', '-setusingnetworktime', 'on')
FileUtils.mkdir_p('/Library/Java/JavaVirtualMachines')
jdk = '/Library/Java/JavaVirtualMachines/homebrew-openjdk.jdk'
target_jdk = '/opt/homebrew/opt/openjdk/libexec/openjdk.jdk'
File.symlink(target_jdk, jdk) if File.directory?(target_jdk) && !File.exist?(jdk) && !File.symlink?(jdk)
puts 'Guest isolation, RPC, SSH, network DNS and clock configured.'
