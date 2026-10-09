require 'json'
require 'fileutils'
require 'digest'
require 'securerandom'
require 'etc'

module GuestControlInstall
  SOURCES = {'control-client.rb'=>'guest/control-client.rb', 'control-commands.rb'=>'guest/control-commands.rb',
             'clipboard.js'=>'lib/clipboard.js', 'skills/mac-control/SKILL.md'=>'guest/skills/mac-control/SKILL.md',
             'core.rb'=>'lib/core.rb', 'profile-plan.rb'=>'lib/profile-plan.rb'}.freeze
  # Exact retired releases, so a different user-installed command with either
  # old name is never removed. No compatibility alias is installed.
  LEGACY_DIGESTS = {
    'vm'=>%w[e4948f3774a05a62e0f0b5ba6c708d3889baf3f942d97611ec02459a7e89e869 d8b6553d526c206d8567393aed56e6a4717bb7727e98bd9f7cd6da26add37b3f],
    'vm-control'=>%w[ec0267a0af0108f406306d9a7601d8452d22abc1944149716247417def4a0613]
  }.freeze
  def self.legacy_digests; LEGACY_DIGESTS; end
  def self.install(account, sources, root:'/usr/local/libexec/agent-vm')
    files = sources.map { |name, content| [File.join(root, name), content, 0644, Process.uid, Process.gid] }
    files << [File.join(account.dir, '.local/bin/mac-control'), sources.fetch('control-client.rb'), 0755, account.uid, account.gid]
    files.each do |path, content, mode, uid, gid|
      FileUtils.mkdir_p(File.dirname(path))
      if File.file?(path) && !File.symlink?(path)
        metadata = File.stat(path)
        next if File.binread(path) == content.b && metadata.uid == uid && metadata.gid == gid && (metadata.mode & 0777) == mode
      end
      temporary = path + '.' + SecureRandom.hex(8)
      begin
        File.open(temporary, File::WRONLY|File::CREAT|File::EXCL, mode) { |file| file.write(content); file.flush; file.fsync }
        File.chmod(mode, temporary)
        File.chown(uid, gid, temporary) if Process.uid.zero?
        File.rename(temporary, path)
      ensure
        File.unlink(temporary) if File.file?(temporary)
      end
    end
    legacy_digests.each do |name, hashes|
      path = File.join(account.dir, '.local/bin', name)
      next unless File.file?(path) && !File.symlink?(path)
      File.unlink(path) if hashes.include?(Digest::SHA256.file(path).hexdigest)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Run this guest installer as root.' unless Process.uid.zero?
  value = JSON.parse(STDIN.read)
  GuestControlInstall.install(Etc.getpwnam(value.fetch('user')), value.fetch('sources'))
end
