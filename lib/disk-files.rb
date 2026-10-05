require_relative 'core'
require 'fiddle'

module AgentVM
  module DiskFiles
    NAMES = %w[config.json disk.img nvram.bin].freeze

    def self.copy(source, target, clone_only: false)
      raise Error, 'Image source must be a regular file, not a symlink.' unless File.file?(source) && !File.symlink?(source)
      FileUtils.mkdir_p(File.dirname(target), mode:0700)
      if clone_only
        clone = Fiddle::Function.new(Fiddle::Handle::DEFAULT['clonefile'],
                                     [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
        unless clone.call(source, target, 0).zero?
          raise Error, 'Copy-on-write cloning failed. Throwaways require the same APFS volume; no full disk copy was attempted.'
        end
        File.chmod(0600, target)
        return
      end
      _, status = Open3.capture2e('/bin/cp', '-c', source, target)
      unless status.success?
        File.unlink(target) if File.file?(target)
        AgentVM.run('/bin/cp', source, target, capture:true)
      end
      File.chmod(0600, target)
    end

    def self.with_lock(directory)
      raise Error, 'Resolve saved memory and shut down the VM first.' unless Dir.glob(File.join(directory, 'state.vzvmsave*')).empty?
      path = File.join(directory, 'config.json')
      raise Error, 'VM configuration is missing or is a symlink.' unless File.file?(path) && !File.symlink?(path)
      File.open(path, File::RDWR) do |file|
        lock = [0, 0, 0, Fcntl::F_WRLCK, 0].pack('q!q!i!s!s!')
        begin
          file.fcntl(Fcntl::F_SETLK, lock)
        rescue Errno::EACCES, Errno::EAGAIN
          raise Error, 'Shut down the source VM first; its disk is in use.'
        end
        # Do not open/close this config inode again inside the block: POSIX
        # record locks belong to the process and any close releases its locks.
        yield
      end
    end

    def self.inventory(directory)
      NAMES.each_with_object({}) do |name, result|
        path = File.join(directory, name)
        raise Error, "Image file missing or unsafe: #{name}" unless File.file?(path) && !File.symlink?(path)
        result[name] = {'size'=>File.size(path), 'sha256'=>Digest::SHA256.file(path).hexdigest}
      end
    end
  end
end
