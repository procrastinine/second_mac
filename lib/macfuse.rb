require 'fiddle'

module AgentVM
  module MacFUSE
    def self.installed?
      File.file?('/usr/local/lib/libfuse.2.dylib')
    end

    def self.ready?
      return false unless installed?
      # Read the registered filesystem list without loading a driver, mounting
      # a volume or requesting approval. A restricted probe fails closed.
      lookup = Fiddle::Function.new(Fiddle::Handle::DEFAULT['getvfsbyname'],
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
      buffer = Fiddle::Pointer.malloc(4096, Fiddle::RUBY_FREE)
      lookup.call('macfuse', buffer).zero?
    rescue Fiddle::DLError, SystemCallError
      false
    end
  end
end
