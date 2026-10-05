require_relative 'core'
require 'etc'

module AgentVM
  module HostPath
    MARKER = '# >>> second_mac: command PATH >>>'.freeze
    POSIX = <<~'SH'.freeze
      case ":${PATH-}:" in
        *":$HOME/.local/bin:"*) ;;
        *) export PATH="$HOME/.local/bin${PATH:+:$PATH}" ;;
      esac
    SH
    FISH = <<~'SH'.freeze
      if not contains -- "$HOME/.local/bin" $PATH
        set -gx PATH "$HOME/.local/bin" $PATH
      end
    SH

    def self.on_path?(directory)
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |entry|
        !entry.empty? && File.identical?(entry, directory)
      end
    end

    def self.homebrew_executable; '/opt/homebrew/bin/brew'; end

    def self.install(vm)
      directory = File.join(Dir.home, '.local/bin')
      command_needed = !on_path?(directory)
      brew = homebrew_executable
      prefix = File.dirname(File.dirname(brew))
      brew_needed = File.executable?(brew) &&
                    (ENV['HOMEBREW_PREFIX'] != prefix || !on_path?(File.join(prefix, 'bin')) || !on_path?(File.join(prefix, 'sbin')))
      return unless command_needed || brew_needed
      shell = File.basename(ENV['SHELL'].to_s.empty? ? Etc.getpwuid.shell : ENV['SHELL'])
      body = POSIX
      paths = case shell
              when 'zsh'
                [File.join(ENV['ZDOTDIR'].to_s.empty? ? Dir.home : File.expand_path(ENV['ZDOTDIR']), '.zshrc')]
              when 'bash'
                # Login Bash reads only the first existing profile; interactive
                # non-login Bash reads .bashrc. Preserve both startup routes.
                profiles = %w[.bash_profile .bash_login .profile].map { |name| File.join(Dir.home, name) }
                [profiles.find { |path| File.exist?(path) || File.symlink?(path) } || profiles.first,
                 File.join(Dir.home, '.bashrc')]
              when 'sh', 'ksh'
                [File.join(Dir.home, '.profile')]
              when 'fish'
                body = FISH
                config = ENV['XDG_CONFIG_HOME'].to_s.empty? ? File.join(Dir.home, '.config') : File.expand_path(ENV['XDG_CONFIG_HOME'])
                [File.join(config, 'fish/config.fish')]
              else
                warn "Shell #{shell} needs manual PATH setup: add ~/.local/bin and initialize Homebrew with brew shellenv; use #{directory}/vm directly meanwhile."
                return
              end
      block = command_needed ? "#{MARKER}\n#{body}# <<< second_mac: command PATH <<<\n" : nil
      brew_command = shell == 'fish' ? "#{Shellwords.escape(brew)} shellenv fish | source" : "eval \"$(#{Shellwords.escape(brew)} shellenv #{shell})\""
      if brew_needed
        brew_body = if shell == 'fish'
                      "if test -x #{Shellwords.escape(brew)}\n  set -gx HOMEBREW_NO_ANALYTICS 1\n  #{brew_command}\nend\n"
                    else
                      "if [ -x #{Shellwords.escape(brew)} ]; then\n  export HOMEBREW_NO_ANALYTICS=1\n  #{brew_command}\nfi\n"
                    end
        brew_block = "# >>> second_mac: Homebrew environment >>>\n#{brew_body}# <<< second_mac: Homebrew environment <<<\n"
      end
      paths.each do |path|
        # Dotfile managers commonly symlink shell startup files. Update their
        # target while preserving the link and a private copy of the original.
        target = File.symlink?(path) ? File.realpath(path) : path
        raise Error, "Shell configuration is not a regular file: #{path}" if File.exist?(target) && !File.file?(target)
        original = File.exist?(target) ? File.binread(target) : ''
        updated = original.dup
        # Homebrew's environment must precede any existing completion/framework
        # setup. We do not install or change the user's completion configuration.
        updated = brew_block + updated if brew_block && !updated.include?(brew_block)
        if block && !updated.include?(block)
          updated += "\n" unless updated.empty? || updated.end_with?("\n")
          updated += block
        end
        next if updated == original
        mode = File.exist?(target) ? File.stat(target).mode & 0777 : 0600
        if File.exist?(target)
          backup = vm.file('shell-config-backups/' + Digest::SHA256.hexdigest(File.expand_path(target)) + '.before-install')
          AgentVM.write(backup, original) unless File.exist?(backup)
        end
        AgentVM.write(target, updated, mode)
      end
      puts 'Configured the shell environment for vm/Homebrew. Open a new terminal to use it.'
      current = []
      current << brew_command if brew_needed
      current << (shell == 'fish' ? 'set -gx PATH "$HOME/.local/bin" $PATH' : 'export PATH="$HOME/.local/bin:$PATH"') if command_needed
      puts 'For this terminal: ' + current.join('; ')
    rescue SystemCallError => e
      raise Error, "Could not configure shell PATH: #{e.message}. The installed command is #{directory}/vm."
    end
  end
end
