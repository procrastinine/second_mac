require_relative 'core'
require_relative 'ports'
require_relative 'files'
require_relative 'gui'
require_relative 'throwaway'
require_relative 'network'
require_relative 'runtime'
require_relative 'audio'
require_relative 'suspend'
require_relative 'power'
require_relative 'credentials'
require_relative 'guest-control'
require_relative 'clipboard'
require 'uri'
require 'base64'

module AgentVM
  class Menu
    def initialize(vm)
      @vm = vm
    end
    def text(value)
      value.to_s.encode('UTF-8', invalid: :replace, undef: :replace).gsub(/[|\x00-\x1f\x7f]/, ' ')[0, 140]
    end
    def info(value, prefix:'')
      # SwiftBar assigns an action to color= rows, even without href/bash.
      # ANSI foreground styling preserves a genuinely actionless menu item.
      foreground = ENV['OS_APPEARANCE'].to_s.downcase == 'dark' ? 97 : 30
      "#{prefix}\e[#{foreground}m#{text(value)}\e[0m | ansi=true symbolize=false"
    end
    def action(title, *args, terminal:false, prefix:'', confirm:nil)
      key = Digest::SHA256.hexdigest(JSON.generate(args))[0,20]
      directory = @vm.file('menu-actions')
      if terminal
        path = File.join(directory, key + '.command')
        body = "#!/bin/sh\nexec #{Shellwords.join([@vm.file('command'), *args])}\n"
        AgentVM.write(path, body, 0755) unless File.file?(path) && File.read(path) == body
      else
        path = File.join(directory, key + '.app')
        executable = File.join(path, 'Contents/MacOS/action')
        info = {'CFBundleExecutable'=>'action', 'CFBundleIdentifier'=>"local.agent-vm.#{@vm.name}.action-#{key}",
                'CFBundleName'=>'Agent VM', 'CFBundlePackageType'=>'APPL', 'LSUIElement'=>true,
                'ActionCommand'=>@vm.file('command'), 'ActionArguments'=>args.map(&:to_s),
                'ActionTitle'=>title, 'ActionLog'=>@vm.file('menu-action.log')}
        info['PortDirection'] = args.last.split('-').first if %w[host-port guest-port].include?(args.last)
        info['ActionConfirmation'] = confirm if confirm
        plist = AgentVM.plist(info)
        destination = File.join(path, 'Contents/Info.plist')
        AgentVM.write(destination, plist, 0644) unless File.file?(destination) && File.read(destination) == plist
        FileUtils.mkdir_p(File.dirname(executable))
        binary = @vm.file('menu-action-native')
        if File.file?(binary) && (!File.exist?(executable) || File.symlink?(executable) || !File.identical?(binary, executable))
          File.unlink(executable) if File.exist?(executable) || File.symlink?(executable)
          File.link(binary, executable)
        end
      end
      "#{prefix}#{text(title)} | href=#{file_url(path)}"
    end
    def file_url(path)
      'file://' + URI::DEFAULT_PARSER.escape(path, /[^a-zA-Z0-9\/_.~-]/)
    end
    def build_helper
      source = File.join(__dir__, 'menu-action.swift')
      digest = Digest::SHA256.file(source).hexdigest
      binary = @vm.file('menu-action-native')
      unless File.executable?(binary) && File.file?(@vm.file('menu-action.sha256')) && File.read(@vm.file('menu-action.sha256')) == digest
        AgentVM.run('/usr/bin/xcrun', 'swiftc', '-O', '-module-cache-path', @vm.file('swift-module-cache'), source, '-o', binary, timeout:120)
        AgentVM.write(@vm.file('menu-action.sha256'), digest)
      end
      AgentVM.run(binary, '--icons', @vm.state)
    end
    def sessions
      output = @vm.rpc('/opt/homebrew/bin/tmux', 'list-sessions', '-F', "\#{session_id}\t\#{session_name}\t\#{session_windows}\t\#{session_attached}", capture:true, timeout:5)
      output.lines.map do |line|
        id, name, windows, attached = line.strip.split("\t", 4)
        next unless id && id.match?(/\A\$\d+\z/) && windows.to_s.match?(/\A\d+\z/) && attached.to_s.match?(/\A\d+\z/)
        [id, name, windows, attached]
      end.compact
    rescue Error
      []
    end
    def resource_lines
      output = @vm.rpc('/usr/bin/top', '-l', '2', '-s', '1', '-n', '0', capture:true, timeout:5)
      cpu = output.lines.grep(/^CPU usage:/).last
      memory = output.lines.grep(/^PhysMem:/).last
      [cpu && info(cpu.strip, prefix:'--'), memory && info(memory.strip.sub('PhysMem:', 'Memory:'), prefix:'--'),
       info('GPU: Metal available; utilization unavailable', prefix:'--')].compact
    rescue Error
      [info('Guest metrics unavailable while starting or busy', prefix:'--')]
    end
    def storage_lines(running:)
      lines = [info("Disk capacity: #{@vm.config['disk_gb']} GB", prefix:'--')]
      disk = File.join(@vm.tart_directory, 'disk.img')
      if File.file?(disk)
        allocated = File.stat(disk).blocks * 512 / 1_000_000_000.0
        lines << info(format('Host disk: %.1f GB allocated', allocated), prefix:'--')
      end
      memory = File.join(@vm.tart_directory, 'state.vzvmsave')
      lines << info(format('Saved memory: %.1f GiB', File.size(memory) / 1024.0**3), prefix:'--') if File.file?(memory)
      if running
        output = @vm.rpc('/bin/df', '-kP', '/System/Volumes/Data', capture:true, timeout:5)
        row = output.lines.last.to_s.split
        if row.length >= 4 && row[3].match?(/\A\d+\z/)
          lines << info(format('Guest free space: %.1f GiB', row[3].to_i / 1024.0**2), prefix:'--')
        end
      end
      lines
    rescue Error, SystemCallError
      (lines || []) + [info('Disk usage unavailable', prefix:'--')]
    end
    def render
      running = @vm.running?
      suspended = !running && @vm.suspended?
      copies = Throwaway.entries
      active_copies = copies.count(&:running?)
      busy = File.open(@vm.file('menu.lock'), File::RDWR | File::CREAT, 0600) do |lock|
        !lock.flock(File::LOCK_EX | File::LOCK_NB)
      end
      state = busy ? 'working…' : (running ? 'on' : (suspended ? 'suspended' : 'off'))
      icon = @vm.file(running || active_copies > 0 ? 'menu-on.png' : 'menu-off.png')
      symbol = File.file?(icon) ? "templateImage=#{Base64.strict_encode64(File.binread(icon))} width=22 height=18" : 'sfimage=desktopcomputer'
      lines = [" | #{symbol} tooltip=\"#{@vm.name}: #{state}; #{active_copies} throwaways running\"", '---',
               info("#{@vm.name} · #{running ? 'Running' : (suspended ? 'Suspended · memory saved' : 'Stopped')}")]
      mounted = Files.new(@vm).mounted?
      if busy
        lines << info('An action is in progress…')
      else
        lines << action(suspended ? 'Resume' : 'Start', 'menu-action', 'start') unless running
        lines << action(running ? 'Shell…' : (suspended ? 'Resume & Shell…' : 'Start & Shell…'), 'ssh', terminal:true)
        gui = GUI.new(@vm)
        if running && gui.active?
          lines << (gui.hidden? ? action('Show desktop', 'menu-action', 'gui') : action('Hide desktop (keep running)', 'menu-action', 'hide-gui'))
        elsif running && live_viewer?(@vm)
          lines << action('Show desktop', 'menu-action', 'gui')
        else
          lines << action(running ? 'Restart with GUI' : (suspended ? 'Resume with GUI' : 'Start with GUI'), 'menu-action', running ? 'gui-restart' : 'gui')
        end
      end
      if mounted
        lines << "Open mounted VM disk | href=#{file_url(File.join(Dir.home, 'VMs', @vm.name))}"
        lines << action('Unmount VM disk', 'menu-action', 'unmount') unless busy
      elsif !busy
        lines << action(running ? 'Mount VM disk in Finder' : (suspended ? 'Resume & Mount VM disk in Finder' : 'Start & Mount VM disk in Finder'), 'menu-action', 'mount')
      end
      entries = AgentVM.share_entries(@vm.config)
      unless entries.empty?
        lines << 'Host folders'
        entries.each do |entry|
          kind = entry['kind'] == 'macfuse' ? 'scoped links' : (entry['read_only'] ? 'read-only' : 'read & write')
          lines << "--#{text(entry['name'])} (#{kind}) | href=#{file_url(entry['host'])}"
        end
      end
      lines.concat(clipboard_lines(@vm, ['menu-action'], busy:busy))
      lines << '---'
      unless busy
        lines << 'Tmux sessions'
        if running
          found = sessions
          lines << info('No sessions', prefix:'--') if found.empty?
          found.each do |id, name, windows, attached|
            lines << action("#{name} · #{windows} windows#{attached == '0' ? '' : ' · attached'}", 'tmux', id, terminal:true, prefix:'--')
          end
        end
        lines << action('New session…', 'tmux', terminal:true, prefix:'--')
      end
      lines.concat(throwaway_lines(copies, busy:busy, source_running:running))
      lines << 'Network'
      lines << info('Host and LAN blocked; explicit TCP ports only', prefix:'--')
      lines.concat(network_lines(@vm, ['menu-action'], busy:busy, prefix:'--'))
      ports = Ports.new(@vm)
      ports.entries.each do |entry|
        side = entry['direction'] == 'host' ? 'guest' : 'host'
        lines << "--#{entry['direction']} :#{entry['from']} → #{side} :#{entry['to']}#{ports.alive?(entry) ? '' : ' (stopped)'}"
        lines << action('Remove forward', 'menu-action', 'remove-port', entry['direction'], entry['from'], prefix:'----') unless busy
      end
      lines << info('No forwarded ports', prefix:'--') if ports.entries.empty?
      unless busy
        lines << action('Forward a host port to guest…', 'menu-action', 'host-port', prefix:'--')
        lines << action('Forward a guest port to host…', 'menu-action', 'guest-port', prefix:'--')
      end
      lines << 'Services'
      lines.concat(service_lines(@vm, ['menu-action'], busy:busy, prefix:'--'))
      lines << 'Resources'
      lines.concat(resource_lines) if running
      lines << info("Configured: #{@vm.config['cpus']} CPUs · #{@vm.config['memory_gb']} GiB RAM", prefix:'--')
      lines << info('CPU / RAM released while stopped', prefix:'--') unless running
      lines.concat(storage_lines(running:running))
      lines << '---'
      unless busy
        lines << 'Updates'
        lines << action('Check VM tools updates…', 'update', '--check', terminal:true, prefix:'--')
        lines << action('Update VM tools…', 'update', terminal:true, prefix:'--')
        lines << '-----'
        lines << action('Check guest macOS updates…', 'update', '--macos', '--check', terminal:true, prefix:'--')
        lines << action('Update guest macOS… (may restart)', 'update', '--macos', terminal:true, prefix:'--')
        lines.concat(sound_lines(@vm, ['menu-action'])) if running
      end
      if running && !busy
        lines << action('Suspend (save memory)', 'menu-action', 'suspend') if Suspend.new(@vm).supported?
        lines << action('Reboot guest macOS', 'menu-action', 'reboot')
        lines << action('Restart VM and macOS', 'menu-action', 'restart')
        lines << action('Shut Down', 'menu-action', 'stop')
      end
      lines << 'Refresh | refresh=true'
      lines.join("\n") + "\n"
    rescue Error
      " | sfimage=exclamationmark.triangle tooltip=\"VM status unavailable\"\n---\nStatus unavailable\n" + action('Show status…', 'status', terminal:true) + "\nRefresh | refresh=true\n"
    end
    def throwaway_lines(copies, busy:, source_running:)
      lines = ["Throwaways (#{copies.length})"]
      lines << info('Independent disks; no host folders by default', prefix:'--')
      lines << info('Copies can run together if CPU / RAM allow', prefix:'--')
      if @vm.suspended?
        lines << info('Resume and shut down the main VM before copying it', prefix:'--')
      elsif !busy
        title = source_running ? 'Shut Down Main & Create Throwaway…' : 'Create Throwaway'
        confirmation = source_running ? 'Shut down the main VM and end its sessions, then make an independent copy? The copy inherits guest files and credentials. Host folders and port forwards are disconnected.' : nil
        lines << action(title, 'menu-action', 'throwaway-create', prefix:'--', confirm:confirmation)
      end
      lines << info('No retained copies', prefix:'--') if copies.empty?
      copies.each do |copy|
        id = copy.config.fetch('throwaway').fetch('id')
        running = copy.running?
        suspended = !running && copy.suspended?
        ready = copy.config['phase'] == 'ready' && File.file?(File.join(copy.tart_directory, 'disk.img'))
        state = running ? 'Running' : (suspended ? 'Suspended' : (ready ? 'Stopped' : 'Incomplete'))
        lines << "--#{text(id)} · #{text(copy.name)} · #{state}"
        lines << info("From #{copy.config['throwaway']['source']} · #{copy.config['throwaway']['created_at']}", prefix:'----')
        lines << info("#{copy.config['cpus']} CPUs · #{copy.config['memory_gb']} GiB RAM · #{copy.config['disk_gb']} GB disk", prefix:'----')
        next if busy
        args = ['menu-action', 'throwaway', id]
        if ready
          lines << action(suspended ? 'Resume' : 'Start', *args, 'start', prefix:'----') unless running
          lines << action(running ? 'Shell…' : (suspended ? 'Resume & Shell…' : 'Start & Shell…'), 'throwaway', 'ssh', id, terminal:true, prefix:'----')
          lines << action('Tmux session…', 'throwaway', 'tmux', id, terminal:true, prefix:'----')
          gui = GUI.new(copy)
          if running && gui.active?
            lines << action(gui.hidden? ? 'Show desktop' : 'Hide desktop (keep running)', *args, gui.hidden? ? 'gui' : 'hide-gui', prefix:'----')
          elsif running && live_viewer?(copy)
            lines << action('Show desktop', *args, 'gui', prefix:'----')
          else
            lines << action(running ? 'Restart with GUI' : (suspended ? 'Resume with GUI' : 'Start with GUI'), *args, running ? 'gui-restart' : 'gui', prefix:'----')
          end
          if Files.new(copy).mounted?
            lines << "----Open mounted disk | href=#{file_url(File.join(Dir.home, 'VMs', copy.name))}"
            lines << action('Unmount disk', *args, 'unmount', prefix:'----')
          else
            lines << action(running ? 'Mount disk in Finder' : (suspended ? 'Resume & Mount disk in Finder' : 'Start & Mount disk in Finder'), *args, 'mount', prefix:'----')
          end
          lines.concat(clipboard_lines(copy, args, busy:busy, prefix:'----'))
          lines << action('Status & resources…', 'throwaway', 'status', id, terminal:true, prefix:'----')
          lines << '----Network'
          lines.concat(network_lines(copy, args, busy:busy, prefix:'------'))
          services = service_lines(copy, args, busy:busy, prefix:'------')
          unless services.empty?
            lines << '----Services'
            lines.concat(services)
          end
          lines << action('Forward a host port to this guest…', *args, 'host-port', prefix:'----')
          lines << action('Forward a guest port to host…', *args, 'guest-port', prefix:'----')
          Ports.new(copy).entries.each do |entry|
            lines << action("Remove #{entry['direction']} port #{entry['from']} → #{entry['to']}", *args, 'remove-port', entry['direction'], entry['from'], prefix:'----')
          end
        end
        if running
          if File.file?(copy.file('runtime/lib/suspend.rb')) && Suspend.new(copy).supported?
            lines << action('Suspend (save memory)', *args, 'suspend', prefix:'----')
          end
          lines << action('Reboot guest macOS', *args, 'reboot', prefix:'----') if File.file?(copy.file('runtime/lib/power.rb'))
          lines << action('Restart VM and macOS', *args, 'restart', prefix:'----') if ready
          lines << action('Shut Down', *args, 'stop', prefix:'----')
          lines << info('Shut down before deleting this copy', prefix:'----')
        elsif suspended
          lines << action('Resume & Shut Down', *args, 'stop', prefix:'----')
          lines << info('Shut down before deleting saved memory', prefix:'----')
        else
          lines << action('Delete Throwaway…', 'menu-action', 'throwaway-delete', id, prefix:'----',
                          confirm:"Permanently delete throwaway #{id} (#{copy.name}) and all changes saved in it? The source VM and host files are kept.")
        end
      end
      lines
    end
    def perform(action, *args)
      if action == 'log'
        AgentVM.run('/usr/bin/open', '-a', 'TextEdit', @vm.file('menu-action.log'))
        return
      end
      lock = File.open(@vm.file('menu.lock'), File::RDWR | File::CREAT, 0600)
      raise Error, 'Another menu action is still running. Wait for its progress window to finish.' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      refresh
      begin
        case action
        when 'throwaway-create'
          @vm.stop if @vm.running?
          Throwaway.new(@vm.name).create
        when 'throwaway-delete'
          raise Error, 'Expected a throwaway ID.' unless args.length == 1
          Throwaway.new(@vm.name).delete(args.first)
        when 'throwaway'
          raise Error, 'Expected a throwaway ID and action.' unless args.length >= 2
          target = Throwaway.new(@vm.name).find(args.shift)
          # Run its saved implementation, just like `vm throwaway ...` does.
          # A main-VM update must not silently migrate a retained copy.
          raise Error, 'Throwaway runtime is missing.' unless File.file?(target.file('runtime/lib/menu.rb'))
          AgentVM.run('/usr/bin/ruby', '-I', target.file('runtime/lib'), '-rmenu', '-e',
            'v=AgentVM::VM.load(ARGV.shift); AgentVM::Menu.new(v).perform_vm_action(v, ARGV.shift, *ARGV)',
            target.name, *args, timeout:1800)
        else perform_vm_action(@vm, action, *args)
        end
      ensure
        lock.close
        refresh
      end
    end
    def clipboard_lines(vm, args, busy:, prefix:'')
      return [] if busy
      if vm.config['throwaway'] && !File.file?(vm.file('runtime/lib/clipboard.rb'))
        return [action('Copy guest password', *args, 'password', prefix:prefix)]
      end
      lines = [prefix + 'Clipboard']
      if vm.running?
        lines << action('Host text → guest', *args, 'clipboard', 'to-guest', prefix:prefix + '--')
        lines << action('Guest text → host', *args, 'clipboard', 'to-host', prefix:prefix + '--')
        lines << prefix + '-----'
        lines << action('Guest password → guest', *args, 'password', '--guest', prefix:prefix + '--')
      end
      lines << action('Guest password → host', *args, 'password', prefix:prefix + '--')
      lines
    end
    def sound_lines(vm, args)
      audio = Audio.new(vm)
      return [] unless audio.attached
      muted = audio.muted?
      return [info('Guest playback state unavailable')] if muted.nil?
      [action(muted ? 'Unmute guest playback' : 'Mute guest playback', *args, 'audio', muted ? 'unmute' : 'mute')]
    end
    def network_lines(vm, args, busy:, prefix:)
      if vm.config['throwaway'] && !File.file?(vm.file('runtime/lib/network.rb'))
        return [info('This copy keeps its original networking', prefix:prefix)]
      end
      lines = [info(Network.new(vm).summary, prefix:prefix)]
      unless busy
        if !vm.config['throwaway'] || File.file?(vm.file('runtime/lib/network-offline.rb'))
          mode = vm.config['network_mode'] == 'off' ? 'on' : 'off'
          lines << action(mode == 'off' ? 'Disconnect network (keep SSH & forwards)' : 'Reconnect network', *args, 'network', mode, prefix:prefix)
        end
        [['Automatic (detect VPN)', 'auto'], ['Native Softnet', 'native'], ['VPN-compatible', 'vpn'], ['Refresh network', 'refresh']].each do |title, mode|
          next if mode == 'refresh' && !vm.running?
          lines << action(title, *args, 'network', mode, prefix:prefix)
        end
      end
      lines
    end
    def live_viewer?(vm)
      return false if vm.config['throwaway'] && !File.file?(vm.file('runtime/lib/runtime.rb'))
      active = Runtime.new(vm).current
      active && active.fetch('features', []).include?('live-ui')
    rescue Error
      false
    end
    def credential_lines(vm, args, busy:, prefix:)
      return [] if vm.config['throwaway'] && !File.file?(vm.file('runtime/lib/credentials.rb'))
      relay = Credentials.new(vm)
      enabled = relay.enabled?
      return [] unless enabled || File.file?(HostCredentials.path)
      lines = [info("OpenRouter host key: #{enabled ? 'enabled for this VM' : 'off for this VM'}", prefix:prefix)]
      lines << action(enabled ? 'Disable OpenRouter host key' : 'Enable OpenRouter host key', *args, 'credential-relay', enabled ? 'off' : 'on', prefix:prefix) unless busy
      lines
    end
    def service_lines(vm, args, busy:, prefix:)
      # Retained copies keep their old implementation. Do not offer new
      # commands to a copy that cannot understand them.
      if vm.config['throwaway'] && !File.file?(vm.file('runtime/lib/service-modes.rb'))
        return credential_lines(vm, args, busy:busy, prefix:prefix)
      end
      running = vm.running?
      key = HostCredentials.available?
      rows = []
      [[Credentials.new(vm), 'OpenRouter', 'credential-relay', key],
       [GuestControl.new(vm), 'Mac control', 'guest-control', vm.ui_available?]].each do |service, title, action_name, available|
        status = if !available then title == 'OpenRouter' ? 'no host key' : 'UI control unavailable'
                 elsif !running then 'stopped with VM'
                 elsif service.enabled? then 'enabled for this run'
                 else 'off for this run'
                 end
        rows << info("#{title}: #{status}; autostart #{service.autostart? ? 'on' : 'off'}", prefix:prefix)
        next if busy
        if title == 'OpenRouter'
          command = vm.config['throwaway'] ? ['throwaway', 'auth', vm.config['throwaway']['id'], 'set'] : ['auth', 'set']
          rows << action(key ? 'Change key & enable OpenRouter…' : 'Add key & enable OpenRouter…', *command, terminal:true, prefix:prefix)
        end
        if running && available
          enabled = service.enabled?
          rows << action("#{enabled ? 'Stop' : 'Start'} #{title} for this run", *args, action_name,
                         enabled ? 'off' : 'on', '--once', prefix:prefix)
        end
        if available || title == 'OpenRouter' || service.autostart?
          rows << action("#{service.autostart? ? 'Disable' : 'Enable'} #{title} at VM start", *args,
                         action_name, 'autostart', service.autostart? ? 'off' : 'on', prefix:prefix)
        end
      end
      rows
    end
    def perform_vm_action(vm, action, *args)
      case action
      when 'start' then vm.start
      when 'stop' then vm.stop
      when 'suspend' then Suspend.new(vm).save
      when 'reboot' then Power.new(vm).reboot
      when 'restart'
        window = GUI.new(vm)
        graphics = window.active? && !window.hidden? ? true : nil
        vm.stop
        vm.start(graphics:graphics)
      when 'mount' then Files.new(vm).mount
      when 'unmount' then Files.new(vm).unmount
      when 'gui' then GUI.new(vm).command([])
      when 'gui-restart' then GUI.new(vm).command(['--restart'])
      when 'hide-gui' then GUI.new(vm).command(['--hide'])
      when 'headless' then GUI.new(vm).command(['--headless'])
      when 'password'
        if args == ['--guest']
          Clipboard.new(vm).copy_password
        elsif args.empty?
          AgentVM.password_command(vm.password, [])
        else
          raise Error, 'Expected no password arguments or --guest.'
        end
      when 'clipboard' then Clipboard.new(vm).command(args)
      when 'network' then Network.new(vm).command(args)
      when 'runtime' then Runtime.new(vm).command(args)
      when 'audio' then Audio.new(vm).command(args)
      when 'credential-relay' then Credentials.new(vm).command(['relay', *args])
      when 'guest-control' then GuestControl.new(vm).command(args)
      when 'share' then AgentVM.run('/usr/bin/open', vm.config['share'])
      when 'remove-port' then Ports.new(vm).remove(*args)
      when 'add-port'
        raise Error, 'Expected direction and two ports.' unless args.length == 3
        vm.start unless vm.running?
        Ports.new(vm).add(*args)
      else raise Error, 'Unknown menu action.'
      end
    end
    def refresh
      return unless @vm.config['swiftbar_plugin']
      system('/usr/bin/open', '-g', 'swiftbar://refreshplugin?name=' + CGI.escape(File.basename(@vm.config['swiftbar_plugin'])), out:File::NULL, err:File::NULL)
    end
    def install(update_app: true)
      build_helper
      require_relative 'swiftbar'
      application = update_app ? SwiftBar.install(@vm) : SwiftBar.application
      raise Error, 'SwiftBar is missing. Run vm menubar install to install the app.' unless application
      value, status = Open3.capture2('/usr/bin/defaults', 'read', 'com.ameba.SwiftBar', 'PluginDirectory', err:File::NULL)
      directory = status.success? ? value.strip : File.join(Dir.home, '.local/share/swiftbar/plugins')
      raise Error, 'SwiftBar plugin directory must be an absolute path.' unless directory.start_with?('/')
      FileUtils.mkdir_p(directory)
      AgentVM.run('/usr/bin/defaults', 'write', 'com.ameba.SwiftBar', 'PluginDirectory', '-string', directory) unless status.success?
      path = File.join(directory, "agent-vm-#{@vm.name}.30s.sh")
      marker = '# Managed by agent-vm installer'
      raise Error, 'Refusing to replace an unrelated SwiftBar plugin.' if File.exist?(path) && !File.read(path).include?(marker)
      body = "#!/bin/sh\n#{marker}\n# <xbar.title>Second Mac</xbar.title>\n# <xbar.desc>VM lifecycle, shells, tmux, files, ports and resource usage.</xbar.desc>\n# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>\n# <swiftbar.refreshOnOpen>false</swiftbar.refreshOnOpen>\n# <swiftbar.runInBash>false</swiftbar.runInBash>\nexec #{Shellwords.escape(@vm.file('command'))} menu\n"
      AgentVM.write(path, body, 0755) unless File.file?(path) && File.read(path) == body && File.executable?(path)
      @vm.config['swiftbar_plugin'] = path
      @vm.save
      AgentVM.run('/usr/bin/open', '-g', '-a', application)
      # Updating this integration must not reload or disturb other plugins.
      refresh
      puts "SwiftBar menu installed: #{path}"
    end
  end
end
