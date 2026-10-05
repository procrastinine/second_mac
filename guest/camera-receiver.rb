#!/usr/bin/ruby
# Private Tart stdin -> decoder -> OBS camera sink. No listening network port.
require 'open3'
require 'fileutils'
require 'json'

generation = ARGV.fetch(0, '')
abort 'Invalid camera generation.' unless generation.match?(/\A[0-9a-f]{32}\z/)
directory = File.join(Dir.home, '.local/state/second-mac')
FileUtils.mkdir_p(directory, mode:0700)
abort 'Unsafe camera state directory.' if File.symlink?(directory)
path = File.join(directory, 'camera.json')
children = []
begin
  lock = File.open(File.join(directory, 'camera.lock'), File::RDWR|File::CREAT, 0600)
  abort 'Another camera receiver is active.' unless lock.flock(File::LOCK_EX|File::LOCK_NB)
  reader, writer = IO.pipe
  sink = File.join(__dir__, 'camera-sink')
  children << Process.spawn(sink, in:reader, out:File::NULL, err:$stderr)
  reader.close
  children << Process.spawn('/opt/homebrew/bin/ffmpeg', '-hide_banner', '-loglevel', 'warning',
    '-nostdin', '-fflags', 'nobuffer', '-flags', 'low_delay', '-probesize', '32768', '-analyzeduration', '100000',
    '-f', 'mpegts', '-i', 'pipe:0', '-an', '-vf', 'scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2',
    '-pix_fmt', 'bgra', '-f', 'rawvideo', 'pipe:1', in:$stdin, out:writer, err:$stderr)
  writer.close
  temporary = path + '.' + Process.pid.to_s
  File.open(temporary, File::WRONLY|File::CREAT|File::EXCL, 0600) do |file|
    file.write(JSON.generate('generation'=>generation, 'pid'=>Process.pid, 'source'=>'OBS Virtual Camera'))
    file.flush; file.fsync
  end
  File.rename(temporary, path)
  %w[TERM INT].each { |signal| Signal.trap(signal) { raise Interrupt } }
  # If either child fails, terminate only the children owned by this receiver.
  children.delete(Process.waitpid(-1))
rescue Interrupt
ensure
  [reader, writer].compact.each { |io| io.close unless io.closed? }
  children.each { |pid| Process.kill('TERM', pid) rescue Errno::ESRCH }
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
  until children.empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    children.delete_if { |pid| Process.waitpid(pid, Process::WNOHANG) rescue true }
    sleep 0.05 unless children.empty?
  end
  children.each { |pid| Process.kill('KILL', pid) rescue Errno::ESRCH }
  children.each { |pid| Process.waitpid(pid) rescue Errno::ECHILD }
  if path && File.file?(path) && JSON.parse(File.read(path))['generation'] == generation
    File.unlink(path)
  end
  lock.close if lock
end
