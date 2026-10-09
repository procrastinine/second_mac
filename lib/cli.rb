#!/usr/bin/ruby
require_relative 'command-catalog'
# Resolve help before loading any VM or operational handler. In particular,
# ssh/agent help must not start a guest, and help works before installation.
begin
  help = AgentVM::CommandCatalog.help_request(ARGV)
  if help
    puts AgentVM::CommandCatalog.help(help)
    exit
  end
  _, discovery_args = AgentVM::CommandCatalog.invocation(ARGV)
  if discovery_args.first == 'completion'
    require_relative 'completion'
    raise AgentVM::CommandCatalog::Error, 'Usage: vm completion bash|zsh' unless discovery_args.length == 2
    puts AgentVM::Completion.shell(discovery_args.last)
    exit
  end
  if discovery_args.first && !AgentVM::CommandCatalog::COMMANDS.key?(discovery_args.first) && !%w[menu menu-action].include?(discovery_args.first)
    raise AgentVM::CommandCatalog::Error, "Unknown command: #{discovery_args.first}. Run vm help."
  end
rescue AgentVM::CommandCatalog::Error => error
  warn "Error: #{error.message}"
  exit 1
end
require_relative 'core'
require_relative 'files'
require_relative 'install'
require_relative 'ports'
require_relative 'menu'
require_relative 'resources'
require_relative 'update'
require_relative 'gui'
require_relative 'profiles'
require_relative 'agents'
require_relative 'backups'
require_relative 'images'
require_relative 'throwaway'
require_relative 'shares-cli'
require_relative 'projects'
require_relative 'guest-commands'
require_relative 'sip'
require_relative 'ui'
require_relative 'permissions'
require_relative 'guest-control'
require_relative 'camera'
require_relative 'microphone'
require_relative 'network'
require_relative 'access'
require_relative 'audio'
require_relative 'runtime'
require_relative 'suspend'
require_relative 'power'
require_relative 'build-cache'
require_relative 'credentials'
require_relative 'clipboard'
$stdout.sync = true
begin
  name = nil
  if ARGV.first == '--name'
    ARGV.shift
    name = ARGV.shift
    raise AgentVM::Error, '--name requires a value' unless name
  end
  command = ARGV.shift || 'status'
  if command == 'images'
    raise AgentVM::Error, 'Usage: vm images' unless ARGV.empty?
    AgentVM::Images.list
    exit
  end
  if command == 'cache'
    AgentVM::BuildCache.new.command(ARGV)
    exit
  end
  exit AgentVM::Throwaway.new(name).command(ARGV) if command == 'throwaway'
  vm = AgentVM::VM.load(name)
  if %w[start stop restart force-stop status mount unmount doctor apply logs check-sleep menu].include?(command)
    if [['--help'], ['-h']].include?(ARGV)
      puts "Usage: vm #{command} (no arguments)"
      exit
    end
    raise AgentVM::Error, "Usage: vm #{command} (no arguments)" unless ARGV.empty?
  end
  raise AgentVM::Error, 'Usage: vm tmux [SESSION]' if command == 'tmux' && ARGV.length > 1
  if vm.config['throwaway'] && command != 'access'
    if %w[update apply].include?(command)
      raise AgentVM::Error, 'Retained throwaways keep their saved software and configuration. Update the main VM and create a new copy instead.'
    end
    cli = vm.file('runtime/lib/cli.rb')
    raise AgentVM::Error, 'The throwaway management snapshot is missing; restore its private state from backup.' unless File.file?(cli)
    exec('/usr/bin/ruby', cli, '--name', vm.name, command, *ARGV) unless File.expand_path(__FILE__) == File.expand_path(cli)
  end
  case command
  when 'auth' then AgentVM::Credentials.new(vm).command(ARGV)
  when 'clipboard' then AgentVM::Clipboard.new(vm).command(ARGV)
  when 'access' then AgentVM::Access.new(vm).command(ARGV)
  when 'audio' then AgentVM::Audio.new(vm).command(ARGV)
  when 'runtime' then AgentVM::Runtime.new(vm).command(ARGV)
  when 'menu' then puts AgentVM::Menu.new(vm).render
  when 'menubar'
    raise AgentVM::Error, 'Usage: vm menubar install' unless ARGV == ['install']
    vm.render_host
    AgentVM::Menu.new(vm).install
  when 'menu-action'
    log = File.open(vm.file('menu-action.log'), 'w', 0600)
    $stdout.reopen(log)
    log.close
    $stderr.reopen($stdout)
    $stdout.sync = true
    puts Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
    AgentVM::Menu.new(vm).perform(*ARGV)
  when 'start' then vm.start
  when 'suspend' then AgentVM::Suspend.new(vm).command(ARGV)
  when 'resume'
    raise AgentVM::Error, 'Usage: vm resume (requires saved memory)' unless ARGV.empty? && (vm.suspended? || File.file?(vm.file('suspend.json')))
    vm.start
  when 'gui' then AgentVM::GUI.new(vm).command(ARGV)
  when 'sip' then AgentVM::SIP.new(vm).command(ARGV)
  when 'ui' then AgentVM::Desktop.new(vm).command(ARGV)
  when 'permissions' then AgentVM::Permissions.new(vm).command(ARGV)
  when 'guest-control' then AgentVM::GuestControl.new(vm).command(ARGV)
  when 'camera' then AgentVM::Camera.new(vm).command(ARGV)
  when 'microphone' then AgentVM::Microphone.new(vm).command(ARGV)
  when 'network' then AgentVM::Network.new(vm).command(ARGV)
  when 'resources' then AgentVM::Resources.new(vm).command(ARGV)
  when 'profiles' then AgentVM::Profiles.new(vm).command(ARGV)
  when 'snapshot' then AgentVM::Backups.new(vm).command(ARGV)
  when 'backup'
    raise AgentVM::Error, 'Usage: vm backup DIRECTORY | vm backup --verify DIRECTORY' unless ARGV.length == 1 || (ARGV.length == 2 && ARGV.first == '--verify')
    backups = AgentVM::Backups.new(vm)
    if ARGV.first == '--verify'
      backups.verify(ARGV.last)
      puts 'Backup checksums verified.'
    else
      backups.stopped { backups.create(ARGV.first) }
    end
  when 'restore'
    raise AgentVM::Error, 'Usage: vm restore DIRECTORY | vm restore --recover' unless ARGV.length == 1
    backups = AgentVM::Backups.new(vm)
    ARGV == ['--recover'] ? backups.recover : backups.restore(ARGV.first)
  when 'mount' then AgentVM::Files.new(vm).mount
  when 'unmount' then AgentVM::Files.new(vm).unmount
  when 'ports'
    ports = AgentVM::Ports.new(vm)
    action = ARGV.shift || 'list'
    case action
    when 'list'
      raise AgentVM::Error, 'Usage: vm ports list' unless ARGV.empty?
      ports.list
    when 'remove'
      raise AgentVM::Error, 'Usage: ports remove host|guest SOURCE_PORT' unless ARGV.length == 2
      ports.remove(ARGV[0], ARGV[1])
    when 'host', 'guest'
      raise AgentVM::Error, 'Specify a source port and optional destination port.' unless (1..2).cover?(ARGV.length)
      AgentVM::Ports.entry(action, ARGV[0], ARGV[1])
      vm.start unless vm.running?
      ports.add(action, ARGV[0], ARGV[1])
    else raise AgentVM::Error, 'Usage: ports [list|host PORT [PORT]|guest PORT [PORT]|remove host|guest PORT]'
    end
  when 'stop' then vm.stop
  when 'reboot'
    raise AgentVM::Error, 'Usage: vm reboot' unless ARGV.empty?
    AgentVM::Power.new(vm).reboot
  when 'restart'
    window = AgentVM::GUI.new(vm)
    graphics = window.active? && !window.hidden? ? true : nil
    vm.stop
    vm.start(graphics:graphics)
  when 'force-stop' then vm.force_stop
  when 'status'
    puts "VM: #{vm.name} (#{vm.running? ? 'running' : (vm.suspended? ? 'suspended' : 'stopped')})"
    puts "Guest: #{vm.config['user']}; #{vm.config['cpus']} CPUs; #{vm.config['memory_gb']} GiB RAM; #{vm.config['disk_gb']} GB sparse ASIF disk"
    entries = AgentVM.share_entries(vm.config)
    puts 'Host sharing: disabled' if entries.empty?
    entries.each do |entry|
      puts "Share: #{entry['host']} -> ~/#{entry['name']} (#{entry['kind']}#{entry['read_only'] ? ', read-only' : ''})"
    end
    puts "Throwaway ID: #{vm.config['throwaway']['id']} (retained until explicitly deleted)" if vm.config['throwaway']
    puts "State: #{vm.state}"
    puts 'Network: ' + AgentVM::Network.new(vm).summary
  when 'projects' then AgentVM::Projects.new(vm).command(ARGV)
  when 'shares' then AgentVM::ShareSettings.new(vm).command(ARGV)
  when 'agents' then AgentVM::Agents.new(vm).command(ARGV)
  when 'ssh', 'tmux', 'pi', 'codex', 'claude'
    ARGV.shift if command != 'tmux' && ARGV.first == '--'
    selected = command
    if %w[pi codex claude].include?(selected) && !vm.config['agents'].include?(selected)
      raise AgentVM::Error, "Install first: agent-vm agents add #{selected}"
    end
    vm.start unless vm.running?
    target = case command
             when 'pi', 'codex', 'claude' then [command] + ARGV
             when 'tmux' then ARGV.empty? ? ['tmux', 'new-session'] : ['tmux', 'attach-session', '-t', ARGV.fetch(0)]
             else ARGV
             end
    args = vm.ssh_args
    args << '-t' if $stdin.tty?
    args << vm.name
    line = command == 'ssh' ? AgentVM::GuestCommands.remote_line(target) : Shellwords.join(target)
    args << line if line && !target.empty?
    exec(*args)
  when 'sudo'
    ARGV.shift if ARGV.first == '--'
    line = AgentVM::GuestCommands.sudo_line(ARGV)
    vm.start unless vm.running?
    # The password goes first on sudo's stdin and is never on a command line;
    # whatever this command was given on stdin follows it to the program.
    IO.popen([*vm.ssh_args, vm.name, line], 'w') do |pipe|
      pipe.write(vm.password + "\n")
      begin
        IO.copy_stream($stdin, pipe) unless $stdin.tty?
      rescue Errno::EPIPE
        nil
      end
    end
    exit($?.exitstatus || 1)
  when 'cp'
    args = AgentVM::GuestCommands.copy_args(vm, ARGV)
    vm.start unless vm.running?
    exec(*args)
  when 'password'
    if ARGV == ['--guest']
      vm.start unless vm.running?
      AgentVM::Clipboard.new(vm).copy_password
    else
      AgentVM.password_command(vm.password, ARGV)
    end
  when 'logs' then exec('/usr/bin/tail', '-n', '80', vm.file('stderr.log'))
  when 'doctor'
    vm.verify_runtime
    vm.start
    vm.ssh('/usr/bin/ruby', vm.home + '/.local/share/agent-vm/doctor.rb', timeout: 60)
  when 'apply'
    source = vm.config['source_directory']
    if source && File.directory?(source) && File.expand_path(source) != File.expand_path('..', __dir__)
      exec('/usr/bin/ruby', File.join(source, 'lib/cli.rb'), '--name', vm.name, 'apply')
    end
    AgentVM::Installer.new(vm.config).apply_configuration(vm)
  when 'update'
    AgentVM::Update.new(vm).command(ARGV)
  when 'check-sleep'
    vm.start unless vm.running?
    puts 'After the first PID, close/reopen the lid and press Enter. The PID must stay the same.'
    exec(*vm.ssh_args, '-tt', vm.name, 'sh -c \'printf "Guest PID: %s\\n" "$$"; read answer; printf "Same guest PID: %s\\n" "$$"\'')
  else raise AgentVM::Error, "Unknown command: #{command}. Run vm help."
  end
rescue AgentVM::Error => e
  warn "Error: #{e.message}"
  exit 1
end
