# frozen_string_literal: true
require 'json'
require 'fileutils'
require 'open3'
require 'shellwords'
require 'timeout'
require 'securerandom'
require 'digest'
require 'cgi'
require 'fcntl'
require 'base64'
require 'ipaddr'
require_relative 'profile-plan'

# Tart initializes tracing when TRACEPARENT is present, including command args.
%w[TRACEPARENT TRACESTATE SENTRY_DSN CIRRUS_SENTRY_TAGS OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_TRACES_ENDPOINT].each { |key| ENV.delete(key) }
ENV['OTEL_SDK_DISABLED'] = 'true'
ENV['DO_NOT_TRACK'] = '1'
ENV['HOMEBREW_NO_ANALYTICS'] = '1'

module AgentVM
  class Error < StandardError; end
  DEFAULTS = { 'name' => 'agent-box', 'user' => 'agent', 'cpus' => 4,
               'memory_gb' => 8, 'disk_gb' => 100, 'share' => '~/vmshare',
               'guest_share' => 'shared_files', 'ipsw' => 'latest',
               'python' => '3', 'pi_model' => 'z-ai/glm-5.3',
               'compact_at' => 400_000, 'timezone' => 'UTC', 'agents' => [], 'sharing'=>'hybrid', 'external_links'=>true,
               'profiles'=>['base'], 'desktop_on_demand'=>true, 'share_read_only'=>false, 'autologin'=>true,
               'source_mode'=>'git', 'network_mode'=>'auto', 'setup'=>'auto', 'credential_relays'=>[] }.freeze
  PRIVATE_NETS = %w[@host 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8
                   169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4].freeze

  def self.state_root
    File.expand_path(ENV.fetch('AGENT_VM_HOME', '~/.local/share/agent-vm'))
  end

  def self.write(path, content, mode = 0600)
    FileUtils.mkdir_p(File.dirname(path), mode: 0700)
    temp = "#{path}.#{Process.pid}.tmp"
    File.open(temp, 'w', mode) { |f| f.write(content); f.flush; f.fsync }
    File.chmod(mode, temp)
    File.rename(temp, path)
  ensure
    File.unlink(temp) if temp && File.exist?(temp)
  end

  def self.json_write(path, value)
    write(path, JSON.pretty_generate(value) + "\n")
  end

  def self.password_command(password, args, guest: false)
    command = guest ? 'mac-control' : 'vm'
    local_option = guest ? '--local' : '--guest'
    args = ['--local'] if guest && args == ['--guest'] # Retain compatibility with saved management runtimes.
    raise Error, "Usage: #{command} password [--copy | --show | #{local_option}]" unless [[], ['--copy'], ['--show'], [local_option]].include?(args)
    if args == ['--show']
      raise Error, 'Password display requires an interactive terminal; it is never printed to redirected logs.' unless $stdout.tty?
      puts password
    elsif guest && !ENV['SSH_CONNECTION'].to_s.empty? && args != ['--local']
      raise Error, 'SSH clipboard copy requires a terminal. Use mac-control password --local for this Mac\'s desktop clipboard.' unless $stdout.tty?
      if !ENV['TMUX'].to_s.empty?
        begin
          run('/opt/homebrew/bin/tmux', 'load-buffer', '-b', 'mac-control-password', '-w', '-', input:password)
        ensure
          run('/opt/homebrew/bin/tmux', 'delete-buffer', '-b', 'mac-control-password', capture:true)
        end
      else
        $stdout.write("\e]52;c;#{Base64.strict_encode64(password)}\a")
        $stdout.flush
      end
      puts 'Password sent to your SSH terminal clipboard. The terminal must allow clipboard writes.'
    else
      run('/usr/bin/pbcopy', input:password)
      puts(guest ? 'Account password copied to this Mac\'s clipboard.' : 'Guest password copied to the host clipboard.')
    end
  end

  def self.run(*args, input: nil, timeout: nil, capture: false, quiet: false)
    log = Thread.current[:agent_vm_command_log]
    if capture || input || timeout || log
      stdout = stderr = status = nil
      Open3.popen3(*args, pgroup: true) do |stdin, out, err, waiter|
        collect = lambda do |stream, display|
          text = +''
          begin
            loop do
              chunk = stream.readpartial(16384)
              text << chunk
              display.write(chunk) unless capture || quiet
            end
          rescue EOFError, IOError
            text
          end
        end
        reader = Thread.new { collect.call(out, log || $stdout) }
        errors = Thread.new { collect.call(err, log || $stderr) }
        writer = Thread.new do
          begin
            stdin.write(input) if input
          rescue Errno::EPIPE, IOError
          ensure
            stdin.close
          end
        end
        begin
          finish = lambda do
            status = waiter.value
            writer.join
            stdout = reader.value
            stderr = errors.value
          end
          timeout ? Timeout.timeout(timeout) { finish.call } : finish.call
          completed = true
        rescue Timeout::Error
          Process.kill('KILL', -waiter.pid) rescue nil
          waiter.value
          raise Error, "Command timed out: #{File.basename(args.first.to_s)}"
        ensure
          unless completed
            # Installer cancellation must also stop its parallel compiler and
            # subprocesses. Open3 otherwise waits for the orphaned command.
            Process.kill('TERM', -waiter.pid) rescue nil
            waiter.join(2)
            Process.kill('KILL', -waiter.pid) rescue nil
            waiter.join
          end
          [stdin, out, err].each { |stream| stream.close unless stream.closed? }
          [writer, reader, errors].each { |thread| thread.kill if thread.alive? }
        end
      end
      unless status.success?
        detail = [stderr.to_s.strip, stdout.to_s].join("\n")
        raise Error, "#{File.basename(args.first.to_s)} failed (#{status.exitstatus}): #{detail[-1500..-1] || detail}"
      end
      stdout
    else
      raise Error, "Command failed: #{Shellwords.join(args)}" unless system(*args)
    end
  end

  def self.validate(config)
    raise Error, 'VM name must be 1-40 lowercase letters, digits or hyphens, starting with a letter.' unless config['name'].match?(/\A[a-z][a-z0-9-]{0,39}\z/)
    raise Error, 'Guest user must start with a letter and contain only lowercase letters, digits or underscores (maximum 31).' unless config['user'].match?(/\A[a-z][a-z0-9_]{0,30}\z/) && config['user'] != 'root'
    raise Error, 'Guest shared-folder name must be a simple directory name.' unless config['guest_share'].match?(/\A[a-zA-Z][a-zA-Z0-9_-]{0,63}\z/)
    raise Error, 'Choose a shared-folder name that does not replace a standard guest directory.' if %w[tools Library Desktop Documents Downloads Public Applications Movies Music Pictures].include?(config['guest_share'])
    { 'cpus' => 2..64, 'memory_gb' => 4..512, 'disk_gb' => 80..4096, 'compact_at' => 32768..2_000_000 }.each do |key, range|
      raise Error, "Invalid #{key}: #{config[key]}" unless config[key].is_a?(Integer) && range.cover?(config[key])
    end
    %w[share ipsw python pi_model timezone].each do |key|
      raise Error, "Invalid #{key}" unless config[key].is_a?(String) && !config[key].empty? && !config[key].match?(/[\x00-\x1f]/)
    end
    config['agents'] ||= []
    config['credential_relays'] ||= []
    raise Error, 'Host credentials currently support openrouter only.' unless config['credential_relays'].is_a?(Array) && (config['credential_relays'] - ['openrouter']).empty?
    config['source_mode'] ||= 'git'
    config['setup'] ||= 'auto'
    raise Error, 'Setup must be auto or manual.' unless %w[auto manual].include?(config['setup'])
    raise Error, 'Invalid saved setup method.' if config['setup_method'] && !%w[native manual].include?(config['setup_method'])
    if config.key?('manual_password_confirmed') && ![true, false].include?(config['manual_password_confirmed'])
      raise Error, 'manual_password_confirmed must be true or false.'
    end
    config['network_mode'] ||= 'auto'
    raise Error, 'Network mode must be auto, native, vpn or off.' unless %w[auto native vpn off].include?(config['network_mode'])
    raise Error, 'Invalid saved network mode.' if config['network_resume_mode'] && !%w[auto native vpn].include?(config['network_resume_mode'])
    config['runtime_mode'] ||= 'auto'
    raise Error, 'Runtime must be auto, standard or custom.' unless %w[auto standard custom].include?(config['runtime_mode'])
    raise Error, 'Source mode must be git or local.' unless %w[git local].include?(config['source_mode'])
    raise Error, 'Supported agents: pi, codex, claude (or none).' unless config['agents'].is_a?(Array) && (config['agents'] - %w[pi codex claude]).empty?
    # Older installations included every tool and used the scoped projection.
    config['profiles'] = ProfilePlan.expand(config.fetch('profiles', ProfilePlan::LEGACY), config['agents'])
    config['sharing'] ||= 'macfuse'
    raise Error, 'Sharing must be hybrid, none, native or macfuse.' unless %w[hybrid none native macfuse].include?(config['sharing'])
    config['desktop_on_demand'] = true unless config.key?('desktop_on_demand')
    config['share_read_only'] = false unless config.key?('share_read_only')
    # Existing hybrid installations keep their linked folder. Only the fresh
    # installer chooses whether to include it from host driver readiness.
    config['linked_files'] = true unless config.key?('linked_files')
    %w[desktop_on_demand share_read_only linked_files].each do |key|
      raise Error, "#{key} must be true or false." unless [true, false].include?(config[key])
    end
    config['autologin'] = true unless config.key?('autologin')
    config['guest_control'] = false unless config.key?('guest_control')
    %w[microphone camera_obs ui_enabled].each do |key|
      config[key] = false unless config.key?(key)
      raise Error, "#{key} must be true or false." unless [true, false].include?(config[key])
    end
    # Earlier Tart launches coupled playback to microphone input. Preserve that
    # choice when upgrading, then allow the two directions to be independent.
    config['audio_output'] = config['microphone'] unless config.key?('audio_output')
    raise Error, 'audio_output must be true or false.' unless [true, false].include?(config['audio_output'])
    raise Error, 'guest_control must be true or false.' unless [true, false].include?(config['guest_control'])
    raise Error, 'autologin must be true or false.' unless [true, false].include?(config['autologin'])
    raise Error, 'Supported agents: pi, codex, claude (or none).' unless config['agents'].is_a?(Array) && (config['agents'] - %w[pi codex claude]).empty?
    config['share'] = File.expand_path(config['share'])
    if config['sharing'] == 'hybrid'
      config['read_only_share'] ||= config['share'] + '_readonly'
      config['linked_share'] ||= config['share'] + '_links'
      config['guest_read_only_share'] ||= 'readonly_files'
      config['guest_linked_share'] ||= 'linked_files'
      raise Error, '--share-read-only applies to single-share modes; hybrid already includes a read-only folder.' if config['share_read_only']
    end
    entries = share_entries(config)
    entries.each do |entry|
      path, name = entry.values_at('host', 'name')
      raise Error, 'Shared paths must be nonempty and cannot contain colons or control characters.' unless path.is_a?(String) && !path.empty? && !path.match?(/[:\x00-\x1f]/)
      raise Error, 'Guest shared-folder names must be simple directory names.' unless name.is_a?(String) && name.match?(/\A[a-zA-Z][a-zA-Z0-9_-]{0,63}\z/)
      raise Error, 'Choose shared-folder names that do not replace standard guest directories.' if %w[tools Library Desktop Documents Downloads Public Applications Movies Music Pictures].any? { |reserved| reserved.casecmp(name).zero? }
    end
    names = entries.map { |entry| entry['name'].downcase }
    raise Error, 'Guest shared-folder names must be distinct.' unless names.uniq == names
    %w[read_only_share linked_share].each { |key| config[key] = File.expand_path(config[key]) if config[key] }
    paths = share_entries(config).map { |entry| File.expand_path(entry['host']) }
    paths.combination(2).each do |a, b|
      raise Error, 'Shared folders must be separate, non-nested directories.' if a == b || a.start_with?(b + '/') || b.start_with?(a + '/')
    end
    config
  rescue ArgumentError => error
    raise Error, error.message
  end

  def self.guest_config(config)
    keys = %w[name user cpus memory_gb disk_gb guest_share guest_read_only_share guest_linked_share python pi_model compact_at timezone agents profiles sharing share_read_only linked_files rpc_label shares_label autologin]
    clean = config.select { |key, _| keys.include?(key) }
    clean.merge('share'=>"/Volumes/#{config.fetch('guest_share')}",
                'read_only_share'=>"/Volumes/#{config.fetch('guest_read_only_share', 'readonly_files')}",
                'linked_share'=>"/Volumes/#{config.fetch('guest_linked_share', 'linked_files')}", 'ipsw'=>'latest')
  end

  def self.busy_share_handles?(output, mount)
    command, current, files = nil, nil, []
    output.each_line do |line|
      key, value = line[0], line[1..-1].chomp
      case key
      when 'p' then command = current = nil
      when 'c' then command = value
      when 'f'
        current = {'c'=>command, 'f'=>value}
        files << current
      else current[key] = value if current
      end
    end
    return !output.empty? if files.empty?
    files.any? do |file|
      # Spotlight holds a read-only reference to every mounted volume root,
      # even with indexing disabled. The kernel's non-forced unmount handles
      # that OS monitor. User files, cwd references and all writes remain busy.
      !(file['c'] == 'mds' && file['f'].match?(/\A\d+\z/) &&
        file['a'] == 'r' && file['t'] == 'DIR' && file['n'] == mount)
    end
  end

  # Stable tags preserve the original mount when an installation changes modes.
  # Existing single-share configurations retain their original behavior.
  def self.share_entries(config)
    mode = config.fetch('sharing', 'macfuse')
    return [] if mode == 'none'
    main = { 'host'=>config.fetch('share'), 'name'=>config.fetch('guest_share'), 'tag'=>'agent-files',
             'kind'=>mode == 'macfuse' ? 'macfuse' : 'native', 'read_only'=>config.fetch('share_read_only', false) }
    return [main] unless mode == 'hybrid'
    entries = [main,
     { 'host'=>config.fetch('read_only_share', config['share'] + '_readonly'),
       'name'=>config.fetch('guest_read_only_share', 'readonly_files'), 'tag'=>'agent-readonly', 'kind'=>'native', 'read_only'=>true }]
    if config.fetch('linked_files', true)
      entries << { 'host'=>config.fetch('linked_share', config['share'] + '_links'),
        'name'=>config.fetch('guest_linked_share', 'linked_files'), 'tag'=>'agent-linked', 'kind'=>'macfuse', 'read_only'=>false }
    end
    entries
  end

  def self.shares(config)
    rows = share_entries(config).map do |entry|
      root = File.realpath(entry['host'])
      raise Error, 'Each host shared path must be a directory.' unless File.directory?(root)
      entry.merge('host'=>root, 'guest'=>"/Users/#{config.fetch('user')}/#{entry['name']}",
        'transport'=>entry['kind'] == 'native' ? 'Native VirtioFS' : 'Host macFUSE projection over VirtioFS', 'live'=>true,
        'links'=>entry['kind'] == 'native' ? 'Literal symlinks resolve in the guest; external host targets are not exported or redacted.' :
          'Host-created file and directory links appear automatically; nested escapes are blocked.')
    end
    rows.combination(2).each do |a, b|
      a, b = a['host'], b['host']
      raise Error, 'Shared folders must resolve to separate, non-nested directories.' if a == b || a.start_with?(b + '/') || b.start_with?(a + '/')
    end
    rows
  end

  def self.blocked_networks(interfaces)
    blocks = PRIVATE_NETS.dup
    interfaces.each_line do |line|
      fields = line.split
      next unless fields.first == 'inet'
      address = IPAddr.new(fields.fetch(1))
      next unless address.ipv4?
      blocks << address.to_s + '/32'
      index = fields.index('netmask')
      next unless index && fields[index + 1].to_s.match?(/\A0x[0-9a-fA-F]{8}\z/)
      bits = format('%032b', fields[index + 1].to_i(16))
      next unless bits.match?(/\A1+0*\z/)
      prefix = bits.count('1')
      # Connected LANs can use public address space (for example on campus).
      # RFC1918 ranges plus host /32s alone do not block those neighboring hosts.
      blocks << address.mask(prefix).to_s + '/' + prefix.to_s
    end
    blocks.uniq
  end

  def self.xml(value)
    case value
    when Hash then '<dict>' + value.map { |k, v| "<key>#{CGI.escapeHTML(k)}</key>#{xml(v)}" }.join + '</dict>'
    when Array then '<array>' + value.map { |v| xml(v) }.join + '</array>'
    when TrueClass then '<true/>'
    when FalseClass then '<false/>'
    when Integer then "<integer>#{value}</integer>"
    else "<string>#{CGI.escapeHTML(value.to_s)}</string>"
    end
  end

  def self.plist(value)
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">#{xml(value)}</plist>\n"
  end

  class VM
    attr_reader :config, :state
    def initialize(config, saved_config: nil)
      @config = AgentVM.validate(config)
      @state = File.join(AgentVM.state_root, config.fetch('name'))
      previous = saved_config || (File.file?(file('config.json')) ? JSON.parse(File.read(file('config.json'))) : {})
      @saved_config = JSON.parse(JSON.generate(previous))
    end
    def self.load(name = nil)
      name ||= File.read(File.join(AgentVM.state_root, 'default')).strip if File.file?(File.join(AgentVM.state_root, 'default'))
      name ||= DEFAULTS['name']
      raise Error, 'Invalid VM name' unless name.match?(/\A[a-z][a-z0-9-]{0,39}\z/)
      path = File.join(AgentVM.state_root, name, 'config.json')
      raise Error, "No managed VM named #{name}. Run install.sh first." unless File.file?(path)
      saved = JSON.parse(File.read(path))
      new(JSON.parse(JSON.generate(saved)), saved_config:saved)
    end
    def name; config.fetch('name'); end
    def home; "/Users/#{config.fetch('user')}"; end
    def file(name); File.join(state, name); end
    def tart; config.fetch('tart'); end
    def needs_custom_tart?
      return false if config['runtime_mode'] == 'standard'
      config['runtime_mode'] == 'custom' || config['ui_enabled'] || config['audio_output'] || config['microphone']
    end
    def configured_ui?; needs_custom_tart? && config['ui_enabled']; end
    def configured_audio_output?; needs_custom_tart? ? config['audio_output'] : config['microphone']; end
    def display_available?
      return configured_ui? unless running?
      receipt = JSON.parse(File.read(file('ui-process.json')))
      receipt['pid'] == running_pid && File.socket?(File.join(tart_directory, 'ui.sock'))
    rescue Errno::ENOENT, JSON::ParserError
      false
    end
    def ui_available?
      return configured_ui? unless running?
      launch = JSON.parse(File.read(file('access-launch.json'))) rescue {}
      return false if launch['pid'] == running_pid && launch['ui_enabled'] == false
      display_available?
    rescue Errno::ENOENT, JSON::ParserError
      false
    end
    def label; config.fetch('host_label', "local.agent-vm.#{name}"); end
    def domain; "gui/#{Process.uid}"; end
    def password; File.read(file('admin-password')).strip; end
    def control_socket(tag)
      # Darwin's UNIX socket paths are limited to 104 bytes. State paths can
      # contain long usernames/spaces, so use an owner-only short directory.
      directory = "/private/tmp/agent-vm-#{Process.uid}"
      begin
        Dir.mkdir(directory, 0700)
      rescue Errno::EEXIST
      end
      st = File.lstat(directory)
      raise Error, 'Unsafe SSH control socket directory.' unless st.directory? && st.uid == Process.uid && (st.mode & 0077).zero?
      File.join(directory, Digest::SHA256.hexdigest(state + "\0" + tag)[0, 32] + '.sock')
    end
    def exclude_backup(*paths)
      output, status = Open3.capture2e('/usr/bin/tmutil', 'destinationinfo')
      unless status.success?
        return puts('Time Machine has no destination; no backup exclusion needed.') if output.include?('No destinations configured')
        raise Error, 'Could not inspect Time Machine destinations. Check tmutil destinationinfo.'
      end
      paths = [File.join(tart_directory, 'disk.img')] if paths.empty?
      AgentVM.run('/usr/bin/tmutil', 'addexclusion', *paths, timeout:30)
      puts 'Excluded managed VM storage from Time Machine; shared host files keep their existing backup settings.'
    end
    def save
      FileUtils.mkdir_p(state, mode:0700)
      File.open(file('config.lock'), File::RDWR | File::CREAT, 0600) do |lock|
        lock.flock(File::LOCK_EX)
        path = file('config.json')
        raise Error, 'VM settings were removed by another command; reload before continuing.' if !File.file?(path) && !@saved_config.empty?
        current = File.file?(path) ? JSON.parse(File.read(path)) : {}
        changes = (@saved_config.keys | config.keys).select do |key|
          [@saved_config.key?(key), @saved_config[key]] != [config.key?(key), config[key]]
        end
        conflicts = changes.select do |key|
          present = [current.key?(key), current[key]]
          present != [@saved_config.key?(key), @saved_config[key]] && present != [config.key?(key), config[key]]
        end
        raise Error, 'Settings changed in another command: ' + conflicts.join(', ') + '. Retry using the current settings.' unless conflicts.empty?
        merged = current.dup
        changes.each { |key| config.key?(key) ? merged[key] = config[key] : merged.delete(key) }
        AgentVM.validate(merged)
        AgentVM.json_write(path, merged) unless current == merged && File.file?(path)
        config.replace(merged)
        @saved_config = JSON.parse(JSON.generate(merged))
      end
    end
    def verify_runtime
      manifest_path = file('source-manifest.json')
      raise Error, 'Runtime manifest missing; run vm apply.' unless File.file?(manifest_path)
      manifest = JSON.parse(File.read(manifest_path))
      changed = manifest.keys.select do |path|
        installed = file('runtime/' + path)
        !File.file?(installed) || Digest::SHA256.file(installed).hexdigest != manifest[path]
      end
      raise Error, 'Installed runtime changed: ' + changed.join(', ') unless changed.empty?
      if config['throwaway']
        puts 'Retained throwaway runtime matches its saved source manifest.'
        return
      end
      source = config['source_directory']
      if source && File.directory?(source)
        paths = %w[lib guest packages].flat_map { |directory| Dir.glob(File.join(source, directory, '**', '*')) }
        paths += %w[agent-vm install.sh bootstrap.sh update.sh].map { |file| File.join(source, file) }
        paths.select! { |path| File.file?(path) }
        current = paths.each_with_object({}) do |path, result|
          relative = path.delete_prefix(source + '/')
          next if %w[guest/config.json guest/homebrew-install.sh guest/tart-guest-agent].include?(relative)
          result[relative] = Digest::SHA256.file(path).hexdigest
        end
        raise Error, 'Repository differs from the installed host runtime; run vm update to synchronize it.' unless current == manifest
        puts 'Installed runtime matches its source manifest and current repository.'
      else
        puts 'Installed runtime matches its source manifest; original repository is unavailable.'
      end
    end
    def tart_directory
      File.join(ENV.fetch('TART_HOME', File.join(Dir.home, '.tart')), 'vms', name)
    end
    def exists?; File.directory?(tart_directory); end
    def running_pid
      # Match Tart's PIDLock(F_GETLK) without invoking tart list, whose ASIF
      # capacity query opens disk images and can interfere with a starting VM.
      lock = [0, 0, 0, Fcntl::F_RDLCK, 0].pack('q!q!i!s!s!')
      File.open(File.join(tart_directory, 'config.json'), 'r') { |f| f.fcntl(Fcntl::F_GETLK, lock) }
      lock.unpack('q!q!i!s!s!')[2]
    rescue Errno::ENOENT
      0
    end
    def running?
      running_pid > 0
    end
    def suspended?; File.file?(File.join(tart_directory, 'state.vzvmsave')); end
    def rpc_socket
      File.join(tart_directory, 'control.sock')
    end
    def ssh_args
      ['/usr/bin/ssh', '-F', file('ssh-config'), '-o', 'BatchMode=yes']
    end
    def ssh(*args, input: nil, timeout: 120, capture: false)
      raise Error, 'VM transport is still starting.' unless File.socket?(rpc_socket)
      AgentVM.run(*ssh_args, name, Shellwords.join(args), input: input, timeout: timeout, capture: capture)
    end
    def root(*args, input: '', timeout: 120)
      ssh('/usr/bin/sudo', '-k', '-S', '-p', '', *args, input: password + "\n" + input, timeout: timeout)
    end
    def rpc(*args, input: nil, timeout: 15, capture: false)
      raise Error, 'VM transport is still starting.' unless File.socket?(rpc_socket)
      command = [tart, 'exec']
      command << '-i' if input
      AgentVM.run(*command, name, *args, input: input, timeout: timeout, capture: capture)
    end
    def bootstrap_args(ip)
      require_relative 'network'
      port = ip == '127.0.0.1' ? Network.new(self).state.fetch('bootstrap_port') : 22
      ['-F', '/dev/null', '-o', "Port=#{port}", '-i', file('id_ed25519'), '-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none',
       '-o', "UserKnownHostsFile=#{file('bootstrap-known-hosts')}", '-o', 'StrictHostKeyChecking=yes',
       '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=120', '-o', 'ConnectTimeout=10']
    end
    def bootstrap_ssh(ip, *args, input: nil, timeout: 120, capture: false)
      AgentVM.run('/usr/bin/ssh', *bootstrap_args(ip), "#{config['user']}@#{ip}", Shellwords.join(args),
                  input: input, timeout: timeout, capture: capture)
    end
    def render_host(graphics: false, restoring:false)
      require_relative 'network'
      AgentVM.write(file('command'), "#!/bin/sh\n# Managed by agent-vm installer\nexport AGENT_VM_HOME=#{Shellwords.escape(AgentVM.state_root)}\nexec /usr/bin/ruby #{Shellwords.escape(file('runtime/lib/cli.rb'))} --name #{name} \"$@\"\n", 0755)
      # ProxyCommand is interpreted by a shell. Quote arguments for that shell,
      # retaining its shell quoting in ssh_config. Double '%' for OpenSSH.
      proxy = Shellwords.join(['/usr/bin/ruby', file('runtime/lib/ssh-proxy.rb'), file('config.json')]).gsub('%', '%%')
      lines = ["Host #{name}", '  HostName 127.0.0.1', "  User #{config['user']}",
               "  ProxyCommand #{proxy}", "  IdentityFile #{file('id_ed25519').gsub('%', '%%').dump}",
               "  UserKnownHostsFile #{file('known-hosts').gsub('%', '%%').dump}", "  HostKeyAlias #{name}",
               '  StrictHostKeyChecking yes', '  IdentitiesOnly yes', '  IdentityAgent none',
               '  ForwardAgent no', '  ForwardX11 no', '  ChannelTimeout none',
               '  ServerAliveInterval 0', '  TCPKeepAlive no', '  ControlMaster no',
               '  ConnectTimeout 15', '  Host *']
      AgentVM.write(file('ssh-config'), lines.join("\n") + "\n")
      AgentVM.write(file('launch.plist'), AgentVM.plist({
        'Label' => label, 'ProgramArguments' => run_args(graphics:graphics),
        'EnvironmentVariables' => {
          'AGENT_VM_HOME'=>AgentVM.state_root, 'HOME'=>Dir.home,
          'TMPDIR'=>AgentVM.run('/usr/bin/getconf', 'DARWIN_USER_TEMP_DIR', capture:true).strip,
          'SECOND_MAC_MANAGED'=>'1',
          'SECOND_MAC_RESUME'=>restoring ? '1' : '0',
          'SECOND_MAC_UI'=>configured_ui? ? '1' : '0',
          'SECOND_MAC_AUDIO_OUTPUT'=>config['audio_output'] ? '1' : '0',
          'SECOND_MAC_MICROPHONE'=>config['microphone'] ? '1' : '0',
          # Upstream creates directory devices from a Swift dictionary. Keep
          # its enumeration stable across standard Tart memory-save/resume.
          'SWIFT_DETERMINISTIC_HASHING'=>'1',
          'DO_NOT_TRACK'=>'1', 'OTEL_SDK_DISABLED'=>'true'
        }.merge(Network.new(self).environment),
        # This plist stays in private state, outside Library/LaunchAgents.
        # It is loaded explicitly by vm start, never at login.
        'RunAtLoad' => true, 'KeepAlive' => false,
        'StandardOutPath' => file('stdout.log'), 'StandardErrorPath' => file('stderr.log')
      }), 0600)
    end
    def run_args(graphics: false)
      blocks = AgentVM.blocked_networks(AgentVM.run('/sbin/ifconfig', capture:true))
      runner = needs_custom_tart? ? config.fetch('ui_tart', tart) : tart
      args = [runner, 'run', name, '--no-clipboard', '--no-usb-accessories', '--net-softnet']
      args << '--no-audio' unless config['microphone']
      args << '--suspendable' if !needs_custom_tart? && !config['microphone']
      graphics = false if needs_custom_tart? && !%w[creating bootstrap].include?(config['phase'])
      args << '--no-graphics' unless graphics
      if %w[creating bootstrap].include?(config['phase'])
        args += ['--net-softnet-allow=in @host', '--net-softnet-block=out @host']
        if config['setup_method'] != 'manual'
          args << "--provisioning-opts=fullName=#{config['user']},username=#{config['user']},password=#{password},logsInAutomatically=#{config['autologin']},enablesRemoteLogin=true"
        end
      else
        args << '--net-softnet-block=' + blocks.uniq.join(',')
      end
      AgentVM.share_entries(config).each do |entry|
        source = entry['kind'] == 'native' ? entry['host'] : file('shared-view')
        args << "--dir=#{source}:tag=#{entry['tag']}#{entry['read_only'] ? ',ro' : ''}"
      end
      args
    end
    def with_lifecycle_lock
      FileUtils.mkdir_p(state, mode:0700)
      File.open(file('lifecycle.lock'), File::RDWR | File::CREAT, 0600) do |lock|
        raise Error, 'Another VM lifecycle or resource operation is in progress.' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        yield
      end
    end
    def launch(graphics: nil)
      with_lifecycle_lock { launch_unlocked(graphics:graphics) }
    end
    def launch_unlocked(graphics: nil, restoring:false)
      return if running?
      if suspended? && !restoring
        require_relative 'suspend'
        checkpoint = Suspend.new(self)
        resume_vm = VM.new(checkpoint.resume_configuration)
        checkpoint.protect_standard_restore
        return resume_vm.launch_unlocked(graphics:graphics, restoring:true)
      end
      if !restoring && File.file?(file('suspend.json'))
        raise Error, 'An incomplete memory checkpoint exists. Inspect it before a cold start; it is never silently discarded.'
      end
      if File.file?(file('sharing-in-progress.json'))
        require_relative 'live-shares'
        LiveShares.new(self).recover
      end
      raise Error, 'A restore was interrupted. Run vm restore --recover before starting.' if File.exist?(file('restore-in-progress.json'))
      # Current-run service choices never carry into a new Tart process.
      %w[guest-control-once.json model-relay-once.json].each do |name|
        File.unlink(file(name)) if File.file?(file(name))
      end
      if needs_custom_tart? && !restoring
        require_relative 'ui-build'
        config['ui_tart'] = UIBuild.new(self).install
        save
      end
      # Custom Tart can attach its own viewer live, even with UI automation
      # disabled. It needs no parked native window at an ordinary shell start.
      custom_viewer = needs_custom_tart? && !%w[creating bootstrap].include?(config['phase'])
      show_desktop = custom_viewer && graphics == true
      hidden = graphics.nil? && !custom_viewer && config['desktop_on_demand'] && !%w[creating bootstrap].include?(config['phase'])
      graphics = custom_viewer ? false : (graphics.nil? ? hidden : graphics)
      if hidden
        require_relative 'gui'
        window = GUI.new(self)
        window.helper
      end
      # Tart publishes control.sock only after VZ start succeeds, but leaves an
      # old socket after shutdown. Remove that stale endpoint before launching;
      # readiness probes must not connect while devices are being initialized.
      [rpc_socket, File.join(tart_directory, 'ui.sock'), File.join(tart_directory, 'runtime.sock')].each do |socket|
        File.unlink(socket) if File.socket?(socket)
      end
      require_relative 'network'
      Network.new(self).prepare
      require_relative 'shared'
      shared = Shared.new(self)
      shared.prepare
      render_host(graphics:graphics, restoring:restoring)
      # Give launchd the signed executable directly so its PID and exit status
      # always describe Tart itself, without a shell/Ruby intermediary.
      system('/bin/launchctl', 'bootout', "#{domain}/#{label}", out:File::NULL, err:File::NULL)
      AgentVM.run('/bin/launchctl', 'bootstrap', domain, file('launch.plist'))
      job = AgentVM.run('/bin/launchctl', 'print', "#{domain}/#{label}", capture:true)
      pid = job[/^\s*pid = (\d+)$/, 1]
      raise Error, 'Tart launch failed; run vm logs for details.' unless pid
      if needs_custom_tart?
        AgentVM.json_write(file('ui-process.json'), {'pid'=>Integer(pid), 'binary'=>config.fetch('ui_tart')})
      elsif File.file?(file('ui-process.json'))
        File.unlink(file('ui-process.json'))
      end
      if graphics
        AgentVM.json_write(file('gui-process.json'), {'pid'=>Integer(pid)})
      elsif File.exist?(file('gui-process.json'))
        File.unlink(file('gui-process.json'))
      end
      shared.owner(Integer(pid))
      # Safe, per-process attachment receipt for `vm access`. Never persist
      # raw launch arguments: provisioning arguments can contain credentials.
      AgentVM.json_write(file('access-launch.json'), {
        'pid'=>Integer(pid), 'shares'=>AgentVM.share_entries(config),
        'configuration'=>config, 'suspendable'=>!needs_custom_tart? && !config['microphone'], 'stable_devices'=>true,
        'runtime'=>needs_custom_tart? ? 'custom' : 'standard', 'ui_enabled'=>configured_ui?,
        'microphone'=>config['microphone'], 'audio_output'=>configured_audio_output?, 'clipboard'=>false, 'usb'=>false
      })
      if show_desktop
        require_relative 'runtime'
        require_relative 'ui'
        wait_for(30, 'Preparing guest desktop') do
          controller = Runtime.new(self)
          current = controller.current
          next false unless current && current.fetch('features', []).include?('live-ui')
          controller.request('op'=>'ui-set', 'enabled'=>configured_ui?) unless display_available?
          Desktop.new(self).request({'op'=>'show'}, timeout:5)
          true
        end
      elsif hidden
        wait_for(30, 'Preparing desktop on demand') do
          AgentVM.run(window.helper, pid, 'hide', capture:true, timeout:5)
          window.hidden?
        end
      end
    rescue StandardError
      # A failed preparation/bootstrap must not leave an idle sharing process.
      begin
        shared.stop if shared && !running?
      rescue StandardError
      end
      raise
    end
    def wait_for(seconds, description, abort_if: nil)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      print description
      loop do
        failure = abort_if.call if abort_if
        raise Error, failure if failure
        begin
          if yield
            puts ' ready'
            return
          end
        rescue Error
        end
        raise Error, "#{description} timed out; inspect #{file('stderr.log')}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        print '.'
        sleep 2
      end
    end
    def sync_shares
      require_relative 'shared'
      AgentVM::Shared.new(self).start
    end
    def start(share: true, graphics: nil, managed_updates: true)
      began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      launch(graphics:graphics) unless running?
      failed_launch = lambda do
        next nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) - began < 3
        job, status = Open3.capture2e('/bin/launchctl', 'print', "#{domain}/#{label}")
        if !running? && (!status.success? || job.match?(/^\s*state = (not running|exited)$/))
          'VM exited before SSH became ready. Run vm logs for the startup error.'
        end
      end
      wait_for(180, 'Waiting for SSH', abort_if:failed_launch) do
        next false unless File.socket?(rpc_socket)
        ssh('/usr/bin/true', timeout: 10, capture: true)
        true
      end
      if File.file?(file('suspend.json'))
        require_relative 'suspend'
        Suspend.new(self).finish_resume
      end
      if config['throwaway'] && !config['throwaway']['guest_configured']
        require_relative 'throwaway'
        Throwaway.configure_guest(self)
      end
      require_relative 'network'
      Network.new(self).configure_dns
      Network.new(self).start_watcher
      if managed_updates
        require_relative 'guest-update'
        AgentVM::GuestUpdate.new(self).synchronize
      end
      sync_shares if share
      require_relative 'ports'
      AgentVM::Ports.new(self).start_all
      start_services if managed_updates
      if graphics && config['autologin']
        wait_for(120, 'Waiting for guest desktop login') do
          ssh('/usr/bin/stat', '-f', '%Su', '/dev/console', capture:true, timeout:10).strip == config['user']
        end
      end
    end
    def start_services
      require_relative 'credentials'
      AgentVM::Credentials.new(self).start
      require_relative 'permissions'
      AgentVM::Permissions.new(self).start_watcher
      require_relative 'guest-control'
      AgentVM::GuestControl.new(self).start
      require_relative 'camera'
      AgentVM::Camera.new(self).start
    end
    def stop
      if suspended? && !running?
        puts 'Resuming saved memory before a clean guest shutdown.'
        start(managed_updates:false)
      end
      with_lifecycle_lock { stop_unlocked }
    end
    def stop_host_services
      require_relative 'credentials'
      AgentVM::Credentials.new(self).stop
      require_relative 'network'
      Network.new(self).stop_watcher
      require_relative 'files'
      AgentVM::Files.new(self).unmount
      require_relative 'ports'
      AgentVM::Ports.new(self).stop_all
      require_relative 'permissions'
      AgentVM::Permissions.new(self).stop_watcher
      require_relative 'guest-control'
      AgentVM::GuestControl.new(self).stop
      require_relative 'camera'
      AgentVM::Camera.new(self).stop
    end
    def stop_unlocked
      stop_host_services
      require_relative 'shared'
      unless running?
        AgentVM::Shared.new(self).stop
        return puts('VM is already stopped.')
      end
      begin
        ssh('/usr/bin/sudo', '-n', '/sbin/shutdown', '-h', 'now', timeout: 15, capture: true)
      rescue Error
        # A successful shutdown can close SSH before it reports its exit code.
      end
      wait_for(90, 'Waiting for clean shutdown') { !running? }
      AgentVM::Shared.new(self).stop
    end
    def force_stop
      with_lifecycle_lock do
        require_relative 'credentials'
        AgentVM::Credentials.new(self).stop
        require_relative 'network'
        Network.new(self).stop_watcher
        require_relative 'files'
        require_relative 'ports'
        require_relative 'shared'
        AgentVM::Files.new(self).unmount
        AgentVM::Ports.new(self).stop_all
        require_relative 'permissions'
        AgentVM::Permissions.new(self).stop_watcher
        require_relative 'guest-control'
        AgentVM::GuestControl.new(self).stop
        require_relative 'camera'
        AgentVM::Camera.new(self).stop
        AgentVM.run(tart, 'stop', name, '--timeout', '0') if running?
        wait_for(15, 'Waiting for VM process exit') { !running? }
        AgentVM::Shared.new(self).stop
      end
    end
  end
end
