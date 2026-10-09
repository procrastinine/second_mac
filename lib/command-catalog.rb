# Help and completion share this catalog. Loading it performs no VM discovery,
# shell commands, network requests, or writes, including on an uninstalled Mac.
require_relative 'profile-plan'

module AgentVM
  module CommandCatalog
    class Error < StandardError; end
    Node = Struct.new(:path, :syntax, :summary, :details, :examples, :options,
                      :values, :arguments, :repeat, :passthrough, :leading, keyword_init:true)
    COMMANDS = {}
    THROWAWAY_ACTIONS = %w[ssh sudo cp tmux gui clipboard mount unmount start stop restart reboot suspend resume status resources password ports network sip permissions ui guest-control microphone audio camera auth].freeze
    GROUPS = {
      'Daily use'=>%w[status access start stop ssh tmux sudo cp gui clipboard mount unmount password],
      'Power and resources'=>%w[suspend resume reboot restart force-stop runtime resources],
      'Access and controls'=>%w[shares projects network ports ui permissions guest-control auth audio microphone camera sip],
      'Maintenance'=>%w[update apply doctor logs profiles agents pi codex claude menubar images cache check-sleep],
      'Copies and backups'=>%w[snapshot backup restore throwaway],
      'Help and completion'=>%w[help completion]
    }.freeze
    RESTART = {'--restart'=>'Apply now by restarting Tart and guest macOS; otherwise queue for the next cold start.'}.freeze
    JSON_OPTION = {'--json'=>'Print structured JSON.'}.freeze
    ONCE = {'--once'=>'Apply only to the current running VM; keep the saved startup choice.'}.freeze

    def self.add(path, syntax, summary, details:'', examples:[], options:{}, values:{}, arguments:[], repeat:false, passthrough:false)
      COMMANDS[path] = Node.new(path:path, syntax:syntax, summary:summary, details:details,
        examples:examples, options:options, values:values, arguments:arguments,
        repeat:repeat, passthrough:passthrough, leading:0)
    end

    add 'status', '', 'Show power state, resources and shared folders.'
    add 'access', '[--json]', 'Inspect actual and configured host access without starting the VM.', options:JSON_OPTION
    add 'start', '', 'Start the VM with its desktop hidden, or resume saved memory.'
    add 'stop', '', 'Shut down cleanly and release CPU/RAM; keep the guest disk.'
    add 'ssh', '[COMMAND [ARG...] | "SHELL LINE"]', 'Open a guest shell or run a guest command.', passthrough:true,
      details:'Starts the VM if needed. Separate arguments are quoted individually; one quoted argument is a shell line. Flags after the remote program belong to that program. Use -- to end vm option handling.',
      examples:["vm ssh 'cd src && make'", 'vm ssh python --help']
    add 'sudo', 'COMMAND [ARG...] | "SHELL LINE"', 'Run a command as guest root using the stored password.', passthrough:true,
      details:'Starts the VM if needed. The stored password is supplied on stdin. Use -- before a command to end vm option handling.', examples:['vm sudo id', "vm sudo 'ls /var/root'"]
    add 'tmux', '[SESSION]', 'Create a persistent guest terminal, or attach to a named session.', arguments:[:none],
      details:'Starts the VM if needed. Without SESSION, create a new session; with SESSION, attach to it. Completion never queries guest tmux.', examples:['vm tmux', 'vm tmux work']
    add 'cp', 'SRC... DEST', 'Copy files between host and guest; prefix guest paths with :.', arguments:[:file], repeat:true,
      details:'Exactly one side must be the guest. Copies directories recursively and starts the VM if needed. Guest paths are not queried during completion.', examples:['vm cp ./project :~/', 'vm cp :~/results ./results']
    add 'gui', '[--hide | --headless | --restart]', 'Show or hide the guest desktop.', options:RESTART.merge('--hide'=>'Hide the existing desktop window.', '--headless'=>'Start without a desktop window.'),
      details:'Show/hide keeps an existing compatible VM process. Changing a strictly headless run requires an explicit restart.'
    add 'mount', '', 'Mount guest files in host Finder; start the VM if needed.'
    add 'clipboard', 'to-guest | to-host', 'Copy plain text once between host and guest clipboards.',
      details:'Run on the host, with the guest running and its configured desktop account logged in. Automatic sharing stays disabled. Text only, up to 1 MiB; no automatic paste. Clipboard content is never printed or logged.',
      examples:['vm clipboard to-guest', 'vm clipboard to-host']
    add 'clipboard to-guest', '', 'Copy the current host text into the guest clipboard once.'
    add 'clipboard to-host', '', 'Copy the current guest text into the host clipboard once.'
    add 'unmount', '', 'Unmount the guest Finder volume.'
    add 'password', '[--guest | --show]', 'Copy the guest password to the host clipboard.',
      options:{'--guest'=>'Copy inside the guest instead; starts it if needed.', '--show'=>'Print the password in this terminal.'}
    add 'suspend', '[discard --yes]', 'Save guest memory and processes, releasing active CPU/RAM.',
      details:'Saved memory preserves processes and tmux. SSH must reconnect after resume. macOS and runtime support determine whether memory saving is available.'
    add 'suspend discard', '--yes', 'Discard saved memory, keeping the disk; unsaved work is lost.', options:{'--yes'=>'Confirm loss of saved memory and running processes.'}
    add 'resume', '', 'Resume saved guest memory and processes; requires a memory checkpoint.'
    add 'reboot', '', 'Reboot guest macOS; keep Tart running when supported.'
    add 'restart', '', 'Cleanly restart Tart and guest macOS; ends guest processes and SSH sessions.'
    add 'force-stop', '', 'Abruptly power off a stuck guest; unsaved work may be lost.'
    add 'runtime', '[status [--json] | auto|standard|custom [--restart]]', 'Inspect or choose the next cold-start Tart runtime.', options:JSON_OPTION
    add 'runtime status', '[--json]', 'Show the configured runtime and actual capabilities.', options:JSON_OPTION
    %w[auto standard custom].each do |mode|
      add "runtime #{mode}", '[--restart]', "Select #{mode} Tart for the next cold start.", options:RESTART
    end
    add 'resources', '[--json | --cpus N --memory GiB --disk GB]', 'Inspect resources or change allocations while stopped.',
      options:JSON_OPTION.merge('--cpus N'=>'Number of virtual CPUs.', '--memory GiB'=>'Memory in GiB.', '--disk GB'=>'Sparse disk capacity in decimal GB; growth only.'),
      details:'CPU/RAM changes apply at the next start. Disk growth is verified; shrinking is rejected.', examples:['vm resources --cpus 4 --memory 8', 'vm resources --json']
    add 'projects', '[list | setup DIRECTORY | remove DIRECTORY]', 'Configure reusable local tools for shared pnpm/npm/uv projects.'
    add 'projects list', '', 'List registered shared projects without starting the guest.'
    add 'projects setup', 'DIRECTORY', 'Install local project settings on both Macs; project files are unchanged.', arguments:[:directory],
      details:'Starts the guest if needed. Keeps pnpm verification enabled and uses separate uv environments. No dependencies are installed and no versions are pinned. Open a new shell afterward.', examples:['vm projects setup ~/vmshare/example']
    add 'projects remove', 'DIRECTORY', 'Remove local settings on both Macs; retain dependencies and environments.', arguments:[:directory]
    add 'shares', '[configure OPTIONS]', 'Show or configure host folders exposed to the guest.'
    add 'shares configure', 'OPTIONS', 'Configure host sharing; existing host files are not moved.',
      options:{'--sharing MODE'=>'Sharing backend: hybrid, native, macfuse or none.', '--share PATH'=>'Writable host folder.', '--guest-share NAME'=>'Guest name for the writable folder.',
        '--read-only-share PATH'=>'Read-only host folder.', '--guest-read-only-share NAME'=>'Guest name for the read-only folder.', '--linked-share PATH'=>'Host folder for scoped linked files.', '--guest-linked-share NAME'=>'Guest name for linked files.',
        '--share-read-only'=>'Make the primary share read-only.', '--no-share-read-only'=>'Make the primary share writable.', '--linked-files'=>'Enable the optional linked folder.', '--no-linked-files'=>'Disable the linked folder.',
        '--external-links'=>'Include explicitly linked directory targets.', '--no-external-links'=>'Exclude external linked targets.'},
      values:{'--sharing'=>%w[hybrid native macfuse none], '--share'=>:directory, '--read-only-share'=>:directory, '--linked-share'=>:directory},
      details:'Changes are live with supported custom Tart; otherwise the VM must be stopped. Saved memory must be resumed first.', examples:['vm shares configure --share ~/vmshare']
    add 'network', '[status|auto|native|vpn|off|on|refresh]', 'Inspect or switch networking while keeping SSH and forwards.'
    {'status'=>'Show the configured and active network backend.', 'auto'=>'Choose a compatible backend automatically.', 'native'=>'Use native Softnet networking.', 'vpn'=>'Use host-socket networking for VPN compatibility.', 'off'=>'Disable external networking; keep explicit forwards and SSH.', 'on'=>'Restore external networking.', 'refresh'=>'Reevaluate the current network configuration.'}.each do |mode, summary|
      add "network #{mode}", '', summary
    end
    add 'ports', '[list | host PORT [PORT] | guest PORT [PORT] | remove host|guest PORT]', 'List or manage explicit host/guest TCP forwards.'
    add 'ports list', '', 'List configured TCP forwards.'
    add 'ports host', 'SOURCE_PORT [GUEST_PORT]', 'Expose one host port to the guest; starts the VM if needed.', arguments:[:none, :none], examples:['vm ports host 8080']
    add 'ports guest', 'SOURCE_PORT [HOST_PORT]', 'Expose one guest port on host localhost; starts the VM if needed.', arguments:[:none, :none], examples:['vm ports guest 3000 8080']
    add 'ports remove', 'host|guest SOURCE_PORT', 'Remove a configured TCP forward.'
    %w[host guest].each { |direction| add "ports remove #{direction}", 'SOURCE_PORT', "Remove a #{direction} forward.", arguments:[direction == 'host' ? :host_port : :guest_port] }
    add 'ui', 'COMMAND', 'Control only the guest desktop through its optional UI controller.'
    %w[enable disable].each { |mode| add "ui #{mode}", '[--restart]', "#{mode.capitalize} the guest UI controller.", options:RESTART }
    {'status'=>'Show guest UI controller status.', 'capabilities'=>'Show controls supported by the running viewer.', 'inspect'=>'Read guest desktop text and controls.', 'show'=>'Show the guest desktop.', 'hide'=>'Hide the guest desktop.', 'approve'=>'Approve one recognized guest permission dialog.'}.each do |mode, summary|
      add "ui #{mode}", '', summary
    end
    add 'ui screenshot', '[FILE.png|-]', 'Save a guest PNG, or write PNG to redirected stdout.', arguments:[:file]
    add 'ui type', '[TEXT]', 'Type US-layout ASCII text, tabs and newlines from an argument or stdin (4096 bytes).', arguments:[:none]
    add 'ui click-text', 'LABEL', 'Click a guest control by its visible text.', arguments:[:none]
    add 'ui click', 'X Y [--button left|right|middle] [--count 1|2|3]', 'Click guest screenshot coordinates.', arguments:[:none, :none], options:{'--button BUTTON'=>'Choose left, right or middle.', '--count N'=>'Click once, twice or three times.'}, values:{'--button'=>%w[left right middle], '--count'=>%w[1 2 3]}
    add 'ui move', 'X Y', 'Move the guest pointer without clicking.', arguments:[:none, :none]
    add 'ui drag', 'X Y TO_X TO_Y [--duration SECONDS]', 'Drag between guest screenshot coordinates.', arguments:[:none, :none, :none, :none], options:{'--duration SECONDS'=>'Drag duration in seconds (0.1–5; default 0.6).'}, values:{'--duration'=>:none}
    add 'ui scroll', 'up|down|left|right [PIXELS] [--at X Y]', 'Scroll a guest pane (default 320 pixels at the display center).', arguments:[%w[up down left right], :none], options:{'--at X Y'=>'Pointer coordinates of the pane to scroll.'}, values:{'--at'=>:none}
    add 'ui key', 'SHORTCUT [--hold-ms MILLISECONDS]', 'Press a guest key or shortcut; default hold is 80 ms on an updated viewer.', arguments:[:none],
      options:{'--hold-ms MILLISECONDS'=>'Hold for 10–5000 ms, then release all keys.'}, values:{'--hold-ms'=>:none},
      examples:['vm ui key cmd+l', 'vm ui key right --hold-ms 500']
    add 'permissions', '[status|check|grant|revoke|extension|auto]', 'Inspect or manage guest app permissions.',
      details:'SIP-on grants use guest Settings where supported; camera/microphone need an initial app request. Direct database grants require explicitly disabling guest SIP. This never grants host permissions.'
    add 'permissions status', '', 'Show guest app permission and automatic-approval status.'
    permission_names = %w[documents desktop downloads network-volumes removable-volumes full-disk accessibility screen-recording input-monitoring camera microphone speech contacts calendar reminders photos all]
    %w[check grant revoke].each do |action|
      add "permissions #{action}", 'APP [PERMISSION...]', "#{action.capitalize} permissions for a guest app path or bundle ID.", arguments:[:none, permission_names], repeat:true,
        details:'Use a guest app path or bundle ID. Apple Events targets use apple-events:TARGET_BUNDLE_ID.', examples:["vm permissions #{action} /Applications/Example.app accessibility"]
    end
    add 'permissions extension', 'camera|network|filesystem APP_LABEL', 'Approve a guest extension by its exact displayed app label.', arguments:[%w[camera network filesystem], :none]
    add 'permissions auto', '[on|off|status]', 'Manage deterministic approval of recognized guest dialogs.'
    add 'permissions auto on', '[--restart] [--disable-sip]', 'Enable automatic guest dialog approval.', options:RESTART.merge('--disable-sip'=>'Explicitly disable guest SIP through Recovery and reboot.')
    add 'permissions auto off', '', 'Disable automatic approval; keep existing guest grants.'
    add 'permissions auto status', '', 'Show the saved automatic-approval setting.'
    add 'guest-control', '[on|off [--once] | status | autostart on|off|status]', 'Let the guest control its own UI and app permissions.'
    add 'auth', '[set|host|guest|relay]', 'Manage host credentials and the guest model relay.'
    add 'auth set', '', 'Enter a host OpenRouter key privately and enable the relay.', details:'The key is entered interactively, never as a command-line argument.'
    add 'auth host', '[--path | --from-guest]', 'Inspect the host key location or explicitly migrate a guest key.', options:{'--path'=>'Print only the host key path.', '--from-guest'=>'Explicitly import the existing guest key.'}
    add 'auth guest', '', 'Use guest-owned credentials instead of the host relay.'
    add 'auth relay', '[on|off [--once] | status | autostart on|off|status]', 'Manage the guest model relay without exposing the host key.'
    %w[guest-control].push('auth relay').each do |path|
      %w[on off].each { |mode| add "#{path} #{mode}", '[--once]', "Turn #{path} #{mode}.", options:ONCE }
      add "#{path} status", '', 'Inspect saved and current-run service state.'
      add "#{path} autostart", 'on|off|status', 'Set or inspect the next-start choice; keep the current-run choice.'
      %w[on off status].each { |mode| add "#{path} autostart #{mode}", '', "Autostart: #{mode}." }
    end
    %w[audio microphone].each do |path|
      add path, '[on|off [--restart] | status]' + (path == 'audio' ? ' | mute|unmute' : ''), path == 'audio' ? 'Manage guest output to host speakers/headphones.' : 'Opt into host microphone input separately from playback.'
      %w[on off].each { |mode| add "#{path} #{mode}", '[--restart]', "Turn #{path} #{mode} at the next cold start.", options:RESTART }
      add "#{path} status", '', "Show configured and attached #{path}."
    end
    %w[mute unmute].each { |mode| add "audio #{mode}", '', "#{mode.capitalize} live guest playback without restarting." }
    add 'camera', '[setup|on|off|status]', 'Manage the separately opted-in OBS camera bridge.'
    {'setup'=>'Install/configure the guest OBS camera bridge.', 'on'=>'Enable the camera bridge.', 'off'=>'Disable the camera bridge.', 'status'=>'Show the camera bridge state.'}.each { |action, summary| add "camera #{action}", '', summary }
    add 'sip', '[status|on|off]', 'Inspect or change guest SIP; changes use Recovery and reboot.', details:'This is a host-only command. Host SIP is never changed.'
    %w[status on off].each { |mode| add "sip #{mode}", '', mode == 'status' ? 'Inspect guest SIP.' : "Turn guest SIP #{mode} using Recovery; reboots the guest." }
    add 'update', '[OPTIONS]', 'Update Second Mac and VM tools; keep guest macOS separate.',
      options:{'--check'=>'Check the selected scope; install nothing.', '--plan'=>'Describe the update without network access or changes.', '--configuration'=>'Apply pending guest changes now, restoring its power state.', '--second-mac-only'=>'Update management code/configuration; retain dependency versions.', '--macos'=>'Update only guest macOS; may reboot.', '--no-pull'=>'Use the current checkout without fetching Git changes.', '--runtime MODE'=>'Select the next-start Tart runtime.', '--system'=>'Legacy alias for the default VM-tools update.', '--no-macos'=>'Legacy alias for the default VM-tools update.'},
      values:{'--runtime'=>%w[auto standard custom]}, details:'Default updates Second Mac, Tart, Softnet, SwiftBar and managed guest helpers together. Running sessions are kept; stopped/suspended guests stay idle. Developer packages and agents use their own updaters.',
      examples:['vm update --check', 'vm update --second-mac-only --no-pull', 'vm update --macos --check']
    add 'apply', '', 'Reapply managed guest settings; starts the VM if needed.'
    add 'doctor', '', 'Check runtime integrity and guest services; starts the VM if needed.'
    add 'logs', '', 'Show the most recent VM startup errors.'
    add 'profiles', '[list | add PROFILE... | install PROFILE...]', 'List or install optional developer-tool profiles.'
    add 'profiles list', '', 'List profiles and the current selection.'
    %w[add install].each do |action|
      add "profiles #{action}", 'PROFILE...', action == 'add' ? 'Select and install new profiles.' : 'Fill missing packages in selected profiles; does not bulk-upgrade.', arguments:[ProfilePlan::DESCRIPTIONS.keys + ['full']], repeat:true, examples:["vm profiles #{action} web science"]
    end
    add 'agents', '[list | add pi codex claude]', 'List or install optional coding agents inside the guest.'
    add 'agents list', '', 'List the selected guest agents.'
    add 'agents add', 'AGENT...', 'Install/update only the named guest agents.', arguments:[%w[pi codex claude]], repeat:true
    %w[pi codex claude].each do |agent|
      add agent, '[ARG...]', "Open #{agent} in the guest; it must already be installed.", passthrough:true,
        details:"Starts the VM if needed. Use vm #{agent} -- --help for the agent's own help."
    end
    add 'menubar', 'install', 'Install the optional SwiftBar menu integration.'
    add 'menubar install', '', 'Install SwiftBar integration using this managed VM.'
    add 'images', '', 'List local pristine OS caches and managed guests without starting them.'
    add 'cache', '[list|clean]', 'Inspect or clean obsolete host compiler intermediates.'
    add 'cache list', '', 'Show current and obsolete host compiler caches.'
    add 'cache clean', '', 'Remove obsolete compiler intermediates; keep current builds and guest data.'
    add 'check-sleep', '', 'Interactively test the same SSH process across physical lid sleep.'
    add 'snapshot', '[list | create NAME | restore NAME | verify NAME | delete NAME]', 'Manage stopped-VM disk checkpoints.',
      details:'Checkpoints include guest data and private credentials, not shared host files or saved memory. Restore keeps a before-restore checkpoint.', examples:['vm snapshot create before-upgrade', 'vm snapshot restore before-upgrade']
    add 'snapshot list', '', 'List saved checkpoints.'
    add 'snapshot create', 'NAME', 'Save a disk checkpoint; shut down the VM first.', arguments:[:none], details:'NAME: 1–80 letters, digits, underscores or hyphens, starting with a letter or digit.'
    %w[restore verify delete].each do |action|
      summary = {'restore'=>'Restore a checkpoint while stopped; preserve a before-restore checkpoint.', 'verify'=>'Verify checkpoint file checksums.', 'delete'=>'Delete one checkpoint; leave the current VM unchanged.'}.fetch(action)
      add "snapshot #{action}", 'NAME', summary, arguments:[:snapshot], examples:["vm snapshot #{action} before-upgrade"]
    end
    add 'backup', '[--verify] DIRECTORY', 'Save or verify an external backup of a stopped VM.', options:{'--verify'=>'Verify an existing backup instead of creating it.'}, arguments:[:directory],
      details:'Includes private guest credentials. Shared host files are outside the backup.', examples:['vm backup ~/backups/agent-box']
    add 'restore', 'DIRECTORY | --recover', 'Restore an external backup, preserving a before-restore checkpoint.', options:{'--recover'=>'Recover an interrupted restore.'}, arguments:[:directory]
    add 'throwaway', '[create] [--name NAME] [SCRIPT [ARG...]] | COMMAND ID', 'Create or manage a retained, independent VM copy.', options:{'--name NAME'=>'Optional new VM name; every copy also has an ID.'}, arguments:[:file], passthrough:true,
      details:'The source must be stopped. New copies have no host shares, forwards or media grants. Existing guest files and credentials are copied. Copies remain until explicitly deleted.', examples:['vm throwaway', 'vm throwaway list', 'vm throwaway ssh ID', 'vm throwaway delete ID']
    add 'throwaway create', '[--name NAME] [SCRIPT [ARG...]]', 'Create a retained copy of the stopped source.', options:{'--name NAME'=>'Optional new VM name.'}, arguments:[:file], passthrough:true
    add 'throwaway list', '[--json]', 'List retained copies and their IDs.', options:JSON_OPTION
    add 'throwaway ls', '[--json]', 'Alias for throwaway list.', options:JSON_OPTION
    add 'throwaway delete', 'ID', 'Delete one retained copy explicitly.', arguments:[:throwaway]
    # These copies of catalog entries describe the same handlers. The ID comes
    # before the delegated command's arguments: throwaway network ID off.
    COMMANDS.values.dup.each do |node|
      next unless (THROWAWAY_ACTIONS + ['access']).include?(node.path.split.first)
      copy = node.dup
      copy.path = 'throwaway ' + node.path
      copy.leading = node.path.include?(' ') ? 0 : 1
      COMMANDS[copy.path] = copy
    end
    add 'help', '[COMMAND [SUBCOMMAND...]]', 'Show this overview or help for one command.'
    add 'completion', 'bash|zsh', 'Print shell completion setup for Bash or zsh.', arguments:[%w[bash zsh]],
      details:'The installer configures supported host shells automatically. For this terminal, evaluate the output. Tab reads local state only; it never starts a VM, contacts SSH or lists remote files.',
      examples:['eval "$(vm completion zsh)"', 'eval "$(vm completion bash)"']

    def self.children(path = '')
      prefix = path.empty? ? '' : path + ' '
      COMMANDS.values.select { |node| node.path.start_with?(prefix) && !node.path.delete_prefix(prefix).include?(' ') }
    end

    def self.option_specs(node)
      node.options.to_h { |syntax, description| [syntax.split.first, [syntax.split[1], description]] }
    end

    def self.usage(node)
      words = node.path.split
      words.insert(2, 'ID') if words.first == 'throwaway' && (THROWAWAY_ACTIONS + ['access']).include?(words[1])
      ['vm', *words, node.syntax].reject(&:empty?).join(' ')
    end

    def self.help(path = '')
      if path.empty?
        lines = ['Usage: vm [--name NAME] COMMAND [OPTIONS]', '']
        GROUPS.each do |group, names|
          lines << group
          names.each { |name| lines << format('  %-15s %s', name, COMMANDS.fetch(name).summary) }
          lines << ''
        end
        return (lines + ['Run vm help COMMAND or vm COMMAND --help for arguments and examples.', 'Nested help: vm help snapshot restore. No command defaults to vm status.']).join("\n")
      end
      node = COMMANDS[path]
      raise Error, "Unknown help topic: #{path}. Run vm help." unless node
      lines = ["Usage: #{usage(node)}", '', node.summary]
      lines += ['', node.details] unless node.details.empty?
      nested = children(path)
      unless nested.empty?
        lines += ['', 'Commands:']
        nested.each { |child| lines << format('  %-16s %s', child.path.split.last, child.summary) }
      end
      lines += ['', 'Options:']
      node.options.each { |option, description| lines << format('  %-27s %s', option, description) }
      lines << '  -h, --help                  Show help without starting or changing a VM.'
      lines << '  --name NAME                 Select a managed VM (place before COMMAND).'
      unless node.examples.empty?
        lines += ['', 'Examples:'] + node.examples.map { |example| '  ' + example }
      end
      lines.join("\n")
    end

    def self.invocation(argv)
      args = argv.dup
      name = nil
      if args.first == '--name'
        args.shift
        name = args.shift
        raise Error, '--name requires a value' if name.nil? || name.empty? || name.start_with?('-')
      end
      [name, args]
    end

    def self.help_request(argv)
      _name, args = invocation(argv)
      first = args.shift
      if %w[help --help -h].include?(first)
        args.pop if %w[--help -h].include?(args.last)
        return args.join(' ')
      end
      path = first.to_s
      node = COMMANDS[path]
      return nil unless node
      leading = node.leading
      until args.empty?
        word = args.shift
        return nil if word == '--'
        return path if %w[--help -h].include?(word)
        return path if word == 'help' && !children(path).empty? && leading.zero?
        option = option_specs(node)[word.split('=').first]
        if option
          args.shift if option.first && !word.include?('=')
        elsif leading > 0
          leading -= 1
        elsif (child = COMMANDS[path + ' ' + word])
          path, node = child.path, child
          leading = node.leading
        elsif node.passthrough
          # Everything after the remote program/script belongs to that program.
          return nil
        end
      end
      nil
    end
  end
end
