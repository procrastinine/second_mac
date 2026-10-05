#!/usr/bin/ruby
require 'json'
require 'open3'
require 'shellwords'
abort 'Run as root with a guest username.' unless Process.uid.zero? && ARGV.length == 1
user = ARGV.fetch(0)
abort 'Invalid username' unless user.match?(/\A[a-z][a-z0-9_]{0,30}\z/)
password = STDIN.read.strip
abort 'Missing guest administrator password' if password.empty?

raise 'Could not enable SMB authentication' unless system('/usr/bin/pwpolicy', '-u', user, '-sethashtypes', 'SMB-NT', 'on')
# Supplying the existing password on stdin regenerates the SMB hash without
# putting a password into argv, shell history or a configuration file.
raise 'Invalid password input' if password.match?(/[\x00-\x1f]/)
quoted = Shellwords.escape(password)
# Authenticate the existing account too: a Secure Token account cannot be
# reset using an unauthenticated root-only password change. dscl's command
# input keeps both old/new passwords out of argv and shell history.
commands = "authonly #{user} #{quoted}\npasswd /Users/#{user} #{quoted} #{quoted}\nquit\n"
output, status = Open3.capture2e({'TERM'=>'dumb'}, '/usr/bin/dscl', '.', stdin_data: commands)
redacted = output.gsub(password, '[REDACTED]')
raise 'Could not register SMB password' unless status.success? && !redacted.match?(/error|failed|denied/i)
shares, status = Open3.capture2('/usr/sbin/sharing', '-l', '-f', 'json')
raise 'Could not list SMB shares' unless status.success?
share_map = JSON.parse(shares)
if share_map.key?('agent-files') && share_map['agent-files']['path'] != '/'
  raise 'Could not replace the previous home share' unless system('/usr/sbin/sharing', '-r', 'agent-files')
  share_map.delete('agent-files')
end
flag = share_map.key?('agent-files') ? '-e' : '-a'
target = flag == '-e' ? 'agent-files' : '/'
options = ['-S', 'Root', '-s', '001', '-g', '000', '-E', '1']
options += ['-n', 'agent-files'] if flag == '-a'
raise 'Could not configure SMB share' unless system('/usr/sbin/sharing', flag, target, *options)
share_map.each do |name, properties|
  system('/usr/sbin/sharing', '-r', name) if properties['path'] == '/Users/' + user + '/Public' && properties['smb_guest_access'] == 1
end
raise 'Could not disable anonymous SMB' unless system('/usr/sbin/sysadminctl', '-smbGuestAccess', 'off')
raise 'Could not enable SMB' unless system('/bin/launchctl', 'enable', 'system/com.apple.smbd')
unless system('/bin/launchctl', 'print', 'system/com.apple.smbd', out:File::NULL, err:File::NULL)
  raise 'Could not start SMB' unless system('/bin/launchctl', 'bootstrap', 'system', '/System/Library/LaunchDaemons/com.apple.smbd.plist')
end
puts 'Encrypted, authenticated SMB root share ready for the private Tart channel.'
