require 'shellwords'
require_relative 'core'

module AgentVM
  # How `vm ssh`, `vm sudo` and `vm cp` turn their arguments into guest work.
  module GuestCommands
    module_function

    # The remote command for ssh. Several arguments are an argv and are quoted
    # word by word. A single argument is a shell line, as with ssh itself:
    # `vm ssh 'ls -la | head'` means what it says, and no program is named
    # with a space in it.
    def remote_line(argv)
      return nil if argv.empty?
      argv.length == 1 ? argv.first : Shellwords.join(argv)
    end

    # The guest command for `vm sudo`. sudo reads the stored admin password
    # from stdin (-S, no prompt, cached credentials dropped first); a shell
    # line runs under /bin/sh so pipes and redirections stay inside root.
    def sudo_line(argv)
      raise Error, 'Usage: vm sudo COMMAND [ARG...] | vm sudo \'SHELL LINE\'' if argv.empty?
      command = argv.length == 1 ? ['/bin/sh', '-c', argv.first] : argv
      Shellwords.join(['/usr/bin/sudo', '-k', '-S', '-p', '', '--', *command])
    end

    # scp arguments for `vm cp SRC... DEST`, where a guest path starts with a
    # colon (:~/dir, :/tmp/x). Exactly one side is the guest: all sources, or
    # the destination. Directories copy recursively.
    def copy_args(vm, argv)
      usage = 'Usage: vm cp SRC... :GUEST_DEST | vm cp :GUEST_SRC... HOST_DEST (guest paths start with ":")'
      raise Error, usage if argv.length < 2 || argv.any? { |arg| arg.start_with?('-') }
      *sources, dest = argv
      upload = dest.start_with?(':') && sources.none? { |path| path.start_with?(':') }
      download = !dest.start_with?(':') && sources.all? { |path| path.start_with?(':') }
      raise Error, usage unless upload || download
      if upload
        missing = sources.reject { |path| File.exist?(path) }
        raise Error, "No such host file: #{missing.first}" unless missing.empty?
      end
      guest = lambda { |path| "#{vm.name}:#{path.delete_prefix(':').then { |rest| rest.empty? ? '.' : rest }}" }
      ['/usr/bin/scp', '-F', vm.file('ssh-config'), '-o', 'BatchMode=yes', '-r', '-q',
       *(upload ? sources : sources.map(&guest)), upload ? guest.call(dest) : dest]
    end
  end
end
