#!/usr/bin/ruby
require 'digest'
require 'fileutils'
require 'tmpdir'

# The bundled PAR launcher uses lipo -extract_family, which newer Apple
# toolchains removed. Keep the vendor binary intact and run its ARM64 slice.
source = '/Library/TeX/texbin/biber'
abort 'Biber is not installed; add the latex profile.' unless File.executable?(source)
fat_headers = %w[cafebabe bebafeca cafebabf bfbafeca]
exec(source, *ARGV) unless fat_headers.include?(File.binread(source, 4).unpack1('H*'))

# Content addressing follows tlmgr/Homebrew updates without vm apply and lets
# concurrent invocations finish using their own version. No release is pinned.
cache = File.join(Dir.home, '.cache/agent-vm/biber', Digest::SHA256.file(source).hexdigest)
FileUtils.mkdir_p(cache, mode:0700)
target = File.join(cache, 'biber')
File.open(File.join(cache, 'build.lock'), File::RDWR | File::CREAT, 0600) do |lock|
  lock.flock(File::LOCK_EX)
  unless File.executable?(target) && !File.symlink?(target)
    Dir.mktmpdir('.build-', cache) do |work|
      temporary = File.join(work, 'biber')
      abort 'Could not prepare the ARM64 Biber executable.' unless system('/usr/bin/lipo', source, '-thin', 'arm64', '-o', temporary)
      File.chmod(0755, temporary)
      File.rename(temporary, target)
    end
  end
end
exec(target, *ARGV)
