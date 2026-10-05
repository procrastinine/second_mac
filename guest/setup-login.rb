#!/usr/bin/ruby
require_relative '../lib/core'
require_relative '../lib/autologin'
require_relative 'install-control'
require 'etc'
raise 'Must run inside the guest as root' unless Process.uid.zero?
base = File.expand_path(__dir__)
config = JSON.parse(File.read(File.join(base, 'config.json')))
user = config.fetch('user')
account = Etc.getpwnam(user)
password = STDIN.read.strip
raise 'Missing guest password' if password.empty? || password.match?(/[\x00-\x1f]/)
directory = '/etc/agent-vm'
metadata = File.lstat(directory)
raise 'Unsafe guest configuration directory' unless metadata.directory? && metadata.uid.zero? && (metadata.mode & 0022).zero?
# Atomic replacement in a root-owned directory prevents redirection through a
# symlink in the user's home/share. Only the guest account can read this file.
secret = File.join(directory, 'admin-password')
AgentVM.write(secret, password + "\n", 0400)
File.chown(account.uid, account.gid, secret)
GuestControlInstall.install(account, {
  'control-client.rb'=>File.read(File.join(base, 'control-client.rb')),
  'core.rb'=>File.read(File.join(base, '..', 'lib/core.rb')),
  'profile-plan.rb'=>File.read(File.join(base, '..', 'lib/profile-plan.rb'))
})
if config.fetch('autologin', true)
  vault = AgentVM.run('/usr/bin/fdesetup', 'status', capture:true)
  raise 'Guest FileVault prevents automatic login. Keep encryption and rerun install.sh with --no-autologin.' unless vault.include?('FileVault is Off.')
  # sysadminctl -autologin set requires a GUI session and can report error 22
  # while exiting successfully over SSH. Configure loginwindow's native files
  # directly so this also works before the first interactive desktop login.
  AgentVM.write('/etc/kcpassword', AgentVM::AutoLogin.encode(password), 0600)
  File.chown(0, 0, '/etc/kcpassword')
  AgentVM.run('/usr/bin/defaults', 'write', '/Library/Preferences/com.apple.loginwindow', 'autoLoginUser', '-string', user)
  AgentVM.run('/usr/bin/defaults', 'write', '/Library/Preferences/com.apple.loginwindow', 'autoLoginUserScreenLocked', '-bool', 'false')
  actual = AgentVM.run('/usr/bin/defaults', 'read', '/Library/Preferences/com.apple.loginwindow', 'autoLoginUser', capture:true).strip
  metadata = File.lstat('/etc/kcpassword')
  valid = metadata.file? && metadata.uid.zero? && (metadata.mode & 0777) == 0600 &&
    AgentVM::AutoLogin.matches?(File.binread('/etc/kcpassword'), password)
  raise 'Guest automatic login credential or account did not take effect' unless actual == user && valid
  puts 'Guest automatic login enabled for the next boot.'
else
  Open3.capture2e('/usr/bin/defaults', 'delete', '/Library/Preferences/com.apple.loginwindow', 'autoLoginUser')
  File.unlink('/etc/kcpassword') if File.exist?('/etc/kcpassword') || File.symlink?('/etc/kcpassword')
  _, status = Open3.capture2e('/usr/bin/defaults', 'read', '/Library/Preferences/com.apple.loginwindow', 'autoLoginUser')
  raise 'Guest automatic login could not be disabled' if status.success?
  puts 'Guest automatic login disabled.'
end
puts 'Guest mac-control helper installed; credentials remain outside shared files.'
