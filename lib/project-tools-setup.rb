require 'json'
require 'fileutils'
require 'securerandom'
require 'shellwords'
require 'open3'

module ProjectToolsSetup
  def self.write(file, data, mode = 0600)
    FileUtils.mkdir_p(File.dirname(file), mode: 0700)
    temporary = file + '.' + SecureRandom.hex(8)
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, mode) { |out| out.write(data); out.flush; out.fsync }
    File.rename(temporary, file)
  ensure
    File.unlink(temporary) if temporary && File.exist?(temporary)
  end

  def self.configure(request, home = Dir.home)
    base = File.join(home, '.local/share/project-tools')
    config = File.join(home, '.config/project-tools/projects.json')
    rows = File.file?(config) ? JSON.parse(File.read(config)).fetch('projects') : []
    root = File.realpath(request.fetch('root'))
    row = request.fetch('entry').merge('root'=>root)
    rows.reject! { |saved| saved.fetch('root') == root }
    reused = false
    if row.fetch('tools').include?('uv') && request.fetch('action') != 'remove'
      existing = File.join(root, '.venv')
      python = File.join(existing, 'bin/python')
      if row.delete('reuse_existing') && File.executable?(python)
        _output, status = Open3.capture2e(python, '-I', '--version')
        reused = status.success?
      end
      row['environment'] = reused ? existing : File.join(home, '.local/share/project-tools/environments', row.fetch('id'))
      %w[uv_cache python_dir].each { |key| FileUtils.mkdir_p(row.fetch(key), mode: 0700) }
    end
    if request.fetch('action') == 'remove'
      write(config, JSON.pretty_generate('projects'=>rows) + "\n")
      return {'root'=>root, 'removed'=>true}
    end
    raise 'Project directory is not writable.' unless File.writable?(root)
    if row.fetch('tools').include?('pnpm')
      store = row.fetch('store')
      if File.exist?(store) || File.symlink?(store)
        stat = File.lstat(store)
        raise 'Package cache must be an owned directory, not a link.' unless stat.directory? && stat.uid == Process.uid
      else
        Dir.mkdir(store, 0700)
      end
    end
    # Probe the actual filesystem. Plain fsync must work before the narrow
    # F_FULLFSYNC fallback can be enabled; no write error is waived.
    probe = File.join(root, '.project-tools-probe-' + SecureRandom.hex(8))
    needs_fallback = false
    begin
      File.open(probe, File::RDWR | File::CREAT | File::EXCL, 0600) do |file|
        file.write('flush probe')
        file.flush
        begin
          file.fcntl(51) # Darwin F_FULLFSYNC
        rescue Errno::ENOTTY, Errno::ENOTSUP, Errno::EINVAL
          file.fsync
          needs_fallback = true
        end
      end
    ensure
      File.unlink(probe) if File.exist?(probe)
    end
    if needs_fallback
      source = File.join(base, 'fsync-compat.c')
      library = File.join(base, 'fsync-compat.dylib')
      write(source, request.fetch('fsync_source'))
      output, status = Open3.capture2e('/usr/bin/clang', '-dynamiclib', '-Wall', '-Wextra', '-Werror', source, '-o', library)
      raise "Cannot build filesystem compatibility: #{output}" unless status.success?
      row['fsync_library'] = library
    else
      row.delete('fsync_library')
    end
    write(File.join(base, 'project-tool.rb'), request.fetch('adapter'), 0755)
    bin = File.join(base, 'bin')
    FileUtils.mkdir_p(bin, mode: 0700)
    %w[pnpm uv].each do |tool|
      link = File.join(bin, tool)
      if File.exist?(link) || File.symlink?(link)
        raise "Unexpected command at #{link}" unless File.symlink?(link) && File.readlink(link) == '../project-tool.rb'
      else
        File.symlink('../project-tool.rb', link)
      end
    end
    rows << row
    write(config, JSON.pretty_generate('projects'=>rows) + "\n")
    shell = File.basename(ENV.fetch('SHELL', '/bin/zsh'))
    raise "Configure PATH manually for #{shell}: #{bin}" unless %w[zsh bash sh].include?(shell)
    files = case shell
            when 'zsh' then %w[.zshenv .zshrc].map { |name| File.join(ENV['ZDOTDIR'].to_s.empty? ? home : ENV['ZDOTDIR'], name) }
            when 'bash'
              profiles = %w[.bash_profile .bash_login .profile].map { |name| File.join(home, name) }
              [profiles.find { |file| File.exist?(file) } || profiles.first, File.join(home, '.bashrc')]
            else [File.join(home, '.profile')]
            end
    block = "# >>> project tools >>>\nexport PNPM_HOME=\"${PNPM_HOME:-$HOME/Library/pnpm}\"\ncase \":$PATH:\" in\n  *\":$PNPM_HOME/bin:\"*) ;;\n  *) export PATH=\"$PNPM_HOME/bin:$PATH\" ;;\nesac\ncase \"$PATH\" in\n  #{Shellwords.escape(bin)}:*) ;;\n  *) export PATH=#{Shellwords.escape(bin)}:\"$PATH\" ;;\nesac\n# <<< project tools <<<\n"
    files.each do |file|
      file = File.realpath(file) if File.symlink?(file)
      original = File.file?(file) ? File.read(file) : ''
      updated = original.sub(/\n?# >>> project tools >>>.*?# <<< project tools <<<\n?/m, "\n").rstrip + "\n" + block
      next if updated == original
      backup = File.join(base, 'shell-backups', File.basename(file))
      write(backup, original) unless File.exist?(backup)
      write(file, updated, File.exist?(file) ? File.stat(file).mode & 0777 : 0600)
    end
    {'root'=>root, 'tools'=>row.fetch('tools'), 'bin'=>bin, 'fsync_fallback'=>needs_fallback, 'environment'=>row['environment'], 'reused_environment'=>reused}
  end
end

if __FILE__ == $0 || $0 == '-e'
  begin
    puts JSON.generate(ProjectToolsSetup.configure(JSON.parse(STDIN.read)))
  rescue StandardError => error
    warn "Project tools setup: #{error.message}"
    exit 1
  end
end
