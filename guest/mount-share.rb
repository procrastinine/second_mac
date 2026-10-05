#!/usr/bin/ruby
require '/usr/local/libexec/agent-vm/core'
require 'etc'

raise 'Run as root' unless Process.uid.zero?
lock = File.open('/etc/agent-vm/mount-shares.lock', File::RDWR | File::CREAT, 0600)
lock.flock(File::LOCK_EX)
config = AgentVM.validate(JSON.parse(File.read('/etc/agent-vm/config.json')))
user = config.fetch('user')
entries = AgentVM.share_entries(config)
record = '/etc/agent-vm/mounted-shares.json'
previous = File.file?(record) ? JSON.parse(File.read(record)) : []
# Older installations have no manifest. Only remove exact managed home links,
# never guest documents or links to other locations.
%w[guest_share guest_read_only_share guest_linked_share].each do |key|
  previous << config[key] if config[key]
end
mounts = AgentVM.run('/sbin/mount', capture:true)
previous.uniq.each do |name|
  raise 'Invalid previous shared folder' unless name.is_a?(String) && name.match?(/\A[a-zA-Z][a-zA-Z0-9_-]{0,63}\z/)
  next if entries.any? { |entry| entry['name'] == name }
  mount, link = "/Volumes/#{name}", "/Users/#{user}/#{name}"
  line = mounts.lines.find { |row| row.include?(" on #{mount} (") }
  if line
    raise 'Unexpected filesystem at retired shared mountpoint' unless line.match?(/\((AppleVirtIOFS|virtiofs)[,) ]/) && File.symlink?(link) && File.readlink(link) == mount
    AgentVM.run('/sbin/umount', mount)
  end
  File.unlink(link) if File.symlink?(link) && File.readlink(link) == mount
  Dir.rmdir(mount) if File.directory?(mount) && !File.symlink?(mount) && Dir.empty?(mount)
end
account = Etc.getpwnam(user)
entries.each do |entry|
  name, tag = entry.values_at('name', 'tag')
  mount, link = "/Volumes/#{name}", "/Users/#{user}/#{name}"
  raise 'Mountpoint is a symlink' if File.symlink?(mount)
  FileUtils.mkdir_p(mount)
  line = mounts.lines.find { |row| row.include?(" on #{mount} (") }
  if line
    raise 'Wrong filesystem at shared mountpoint' unless line.match?(/\((AppleVirtIOFS|virtiofs)[,) ]/)
  else
    raise 'The guest mountpoint is not empty' unless Dir.empty?(mount)
    options = entry['read_only'] ? 'nobrowse,ro' : 'nobrowse'
    AgentVM.run('/sbin/mount_virtiofs', '-o', options, tag, mount)
  end
  if File.symlink?(link)
    raise 'Guest shared-folder path is already a different symlink' unless File.readlink(link) == mount
  elsif File.exist?(link)
    raise 'Guest shared folder contains files; move them before mounting' unless File.directory?(link) && Dir.empty?(link)
    Dir.rmdir(link)
    File.symlink(mount, link)
  else
    File.symlink(mount, link)
  end
  File.lchown(account.uid, account.gid, link)
end
names = entries.map { |entry| entry['name'] }
AgentVM.json_write(record, names) unless File.file?(record) && JSON.parse(File.read(record)) == names
