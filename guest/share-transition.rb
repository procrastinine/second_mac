# Executed over the existing authenticated transport; no persistent guest daemon.
require '/usr/local/libexec/agent-vm/core'
raise 'Run as root' unless Process.uid.zero?
action = ARGV.fetch(0)
path = '/etc/agent-vm/config.json'
config = JSON.parse(File.read(path))
label = config.fetch('shares_label', 'local.agent-vm.shares')
raise 'Invalid sharing service label' unless label.match?(/\Alocal\.[a-zA-Z0-9.-]+\z/)
helper = '/usr/local/libexec/agent-vm/mount-share.rb'
start = lambda do
  AgentVM.run('/usr/bin/ruby', helper)
  unless system('/bin/launchctl', 'print', 'system/'+label, out:File::NULL, err:File::NULL)
    AgentVM.run('/bin/launchctl', 'bootstrap', 'system', '/Library/LaunchDaemons/'+label+'.plist')
  end
end
case action
when 'pause'
  # Stop the periodic mounter before unmounting. Never force busy files away.
  system('/bin/launchctl', 'bootout', 'system/'+label, out:File::NULL, err:File::NULL)
  begin
    lock = File.open('/etc/agent-vm/mount-shares.lock', File::RDWR|File::CREAT, 0600)
    lock.flock(File::LOCK_EX)
    mounts = AgentVM.run('/sbin/mount', capture:true)
    active = AgentVM.share_entries(config).map do |entry|
      mount = '/Volumes/'+entry.fetch('name')
      line = mounts.lines.find { |row| row.include?(" on #{mount} (") }
      next unless line
      raise 'Unexpected filesystem at managed mountpoint' unless line.match?(/\((AppleVirtIOFS|virtiofs)[,) ]/)
      mount
    end.compact
    active.each do |mount|
      # VirtioFS can permit unmount despite a process retaining a directory/file
      # handle. Refuse those references explicitly before changing its source.
      output, status = Open3.capture2e('/usr/sbin/lsof', '-nP', '-Fpcfatn', '+f', '--', mount)
      unless (status.exitstatus == 1 && output.empty?) || (status.success? && !AgentVM.busy_share_handles?(output, mount))
        raise "Shared folder is in use: #{mount}; close its files and leave its working directories first."
      end
    end
    active.each do |mount|
      AgentVM.run('/sbin/umount', mount)
    end
  rescue Exception
    lock.close if lock && !lock.closed?
    start.call
    raise
  ensure
    lock.close if lock && !lock.closed?
  end
when 'apply'
  proposed = AgentVM.validate(JSON.parse(STDIN.read))
  keys = %w[sharing share guest_share read_only_share guest_read_only_share linked_share guest_linked_share share_read_only linked_files]
  AgentVM.json_write(path, config.merge(proposed.select { |key, _| keys.include?(key) }))
  File.chmod(0644, path)
  start.call
when 'resume'
  start.call
else
  raise 'Unknown sharing transition'
end
