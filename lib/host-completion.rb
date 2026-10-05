require_relative 'core'
require_relative 'completion'
require 'etc'

module AgentVM
  module HostCompletion
    MARKER = '# >>> second_mac: shell completion >>>'.freeze
    END_MARKER = '# <<< second_mac: shell completion <<<'.freeze

    def self.install(vm)
      shell = File.basename(ENV['SHELL'].to_s.empty? ? Etc.getpwuid.shell : ENV['SHELL'])
      return unless %w[bash zsh].include?(shell)
      # A stable source line survives content-based runtime replacement. The
      # scripts live in private host state and are never copied to the guest.
      script = vm.file('completion.' + shell)
      content = Completion.shell(shell, backend:vm.file('runtime/lib/completion.rb'), root:AgentVM.state_root)
      AgentVM.write(script, content) unless File.file?(script) && File.read(script) == content
      paths = if shell == 'zsh'
                [File.join(ENV['ZDOTDIR'].to_s.empty? ? Dir.home : File.expand_path(ENV['ZDOTDIR']), '.zshrc')]
              else
                profiles = %w[.bash_profile .bash_login .profile].map { |name| File.join(Dir.home, name) }
                [profiles.find { |path| File.exist?(path) || File.symlink?(path) } || profiles.first, File.join(Dir.home, '.bashrc')]
              end
      block = "#{MARKER}\n[ ! -r #{Shellwords.escape(script)} ] || source #{Shellwords.escape(script)}\n#{END_MARKER}\n"
      paths.each do |path|
        target = File.symlink?(path) ? File.realpath(path) : path
        raise Error, "Shell configuration is not a regular file: #{path}" if File.exist?(target) && !File.file?(target)
        original = File.exist?(target) ? File.binread(target) : ''
        pattern = /^#{Regexp.escape(MARKER)}\n.*?^#{Regexp.escape(END_MARKER)}\n?/m
        updated = if original.match?(pattern)
                    original.sub(pattern, block)
                  else
                    original + (original.empty? || original.end_with?("\n") ? '' : "\n") + block
                  end
        next if updated == original
        if File.exist?(target)
          backup = vm.file('shell-config-backups/' + Digest::SHA256.hexdigest(File.expand_path(target)) + '.before-install')
          AgentVM.write(backup, original) unless File.exist?(backup)
        end
        AgentVM.write(target, updated, File.exist?(target) ? File.stat(target).mode & 0777 : 0600)
      end
    rescue SystemCallError => error
      raise Error, "Could not configure shell completion: #{error.message}. Use vm completion #{shell} for manual setup."
    end
  end
end
