require 'fileutils'

path = ARGV.shift
abort 'Expected an installation lock path and command.' unless path && !ARGV.empty?
FileUtils.mkdir_p(File.dirname(path), mode:0700)
lock = File.open(path, File::RDWR | File::CREAT, 0600)
unless lock.flock(File::LOCK_EX | File::LOCK_NB)
  abort 'Guest setup is still running from an earlier connection. Let it finish, then rerun the installer.'
end
exit if ARGV == ['--check']
# Keep the lock in the executed installer, even if its SSH connection closes.
# Root operations acquire it after sudo, which otherwise closes inherited FDs.
lock.close_on_exec = false
exec(*ARGV, close_others:false)
