#!/usr/bin/ruby
require_relative 'install'
require_relative 'images'
require_relative 'macfuse'
require 'optparse'
$stdout.sync = true

module AgentVM::InstallCLI
  def self.run(argv)
    config = AgentVM::DEFAULTS.dup
    supplied = {}
    update, integrations, plan, images = false, true, false, false
    parser = OptionParser.new do |o|
      o.banner = 'Usage: ./install.sh [options] (macOS 26+, Apple Silicon, Homebrew)'
      { 'name' => 'VM and SSH alias', 'user' => 'Guest username', 'share' => 'Host shared directory',
        'guest-share' => 'Guest writable folder name', 'read-only-share' => 'Host read-only folder (default: SHARE_readonly)',
        'guest-read-only-share' => 'Guest read-only folder name (default: readonly_files)',
        'linked-share' => 'Host scoped-link folder (default: SHARE_links)',
        'guest-linked-share' => 'Guest scoped-link folder name (default: linked_files)', 'ipsw' => 'latest, local path or HTTPS URL',
        'python' => 'uv Python selector (default: latest stable 3)', 'pi-model' => 'OpenRouter model ID',
        'timezone' => 'Guest timezone (default: host timezone)',
        'source-mode' => 'git (default) pulls updates; local uses your checkout without fetching' }.each do |flag, desc|
        o.on("--#{flag} VALUE", desc) { |v| supplied[flag.tr('-', '_')] = v }
      end
      { 'cpus' => 'Virtual CPUs', 'memory' => 'RAM in GiB', 'disk' => 'Disk capacity in GB', 'compact-at' => 'Pi compaction threshold' }.each do |flag, desc|
        key = { 'memory' => 'memory_gb', 'disk' => 'disk_gb' }.fetch(flag, flag.tr('-', '_'))
        o.on("--#{flag} NUMBER", Integer, desc) { |v| supplied[key] = v }
      end
      o.on('--agents LIST', 'Comma-separated pi,codex,claude; default none') { |v| supplied['agents'] = v == 'none' ? [] : v.split(',').uniq }
      o.on('--host-credentials PROVIDER', %w[openrouter none], 'openrouter or none (default: offer optional host key with Pi)') { |v| supplied['credential_relays'] = v == 'none' ? [] : [v] }
      o.on('--profiles LIST', 'base (default), web,science,documents,media,build,latex or full') { |v| supplied['profiles'] = AgentVM::ProfilePlan.expand(v.split(',')) }
      o.on('--images', 'List reusable local OS caches and managed VM images') { images = true }
      o.on('--fresh', 'Ignore pristine image caches and resolve the selected restore image') { supplied['fresh'] = true }
      o.on('--setup MODE', 'auto (default: native provisioning when available) or manual Setup Assistant') { |v| supplied['setup'] = v }
      o.on('--from-vm NAME', 'Explicitly copy a stopped managed VM, including its guest data and credentials') { |v| supplied['source_vm'] = v }
      o.on('--sharing MODE', 'hybrid (default: native RW/RO, optional links), native, macfuse, or none') { |v| supplied['sharing'] = v }
      o.on('--[no-]linked-files', 'Include the hybrid linked folder (default: detect ready host macFUSE)') { |v| supplied['linked_files'] = v }
      o.on('--network-mode MODE', 'auto (default), native Softnet, or vpn-compatible host sockets') { |v| supplied['network_mode'] = v }
      o.on('--runtime MODE', 'auto (default), standard or custom Tart; custom adds live controls') { |v| supplied['runtime_mode'] = v }
      o.on('--share-read-only', 'Read-only primary folder in native or macfuse mode') { supplied['share_read_only'] = true }
      o.on('--[no-]desktop-on-demand', 'Keep a hidden native window ready (default: enabled)') { |v| supplied['desktop_on_demand'] = v }
      o.on('--menubar', 'Install the optional SwiftBar VM menu') { supplied['menubar'] = true }
      o.on('--[no-]ui', 'Build optional guest-only UI control alongside macOS installation') { |value| supplied['ui_enabled'] = value }
      o.on('--[no-]audio-output', 'Guest playback through host speakers/headphones; microphone stays off (default: off)') { |value| supplied['audio_output'] = value }
      o.on('--[no-]guest-control-autostart', 'Start mac-control with the VM (default: on with --ui; enables guest UI on new installs)') do |value|
        supplied['guest_control'] = value
        supplied['ui_enabled'] = true if value
      end
      o.on('--[no-]autologin', 'Guest desktop automatically logs in (default: enabled)') { |value| supplied['autologin'] = value }
      o.on('--no-external-links', 'Keep ordinary symlinks but do not export host targets outside the share') { supplied['external_links'] = false }
      o.on('--update', 'Update Second Mac and VM tools; keep guest macOS (same as vm update)') { update = true }
      o.on('--no-integrations', 'Do not add a global command or SSH alias') { integrations = false }
      o.on('--plan', 'Print settings and steps without writing or installing') { plan = true }
      o.on('-h', '--help') { puts o; return 0 }
    end
    parser.parse!(argv)
    raise AgentVM::Error, "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    if images
      AgentVM::Images.list
      return 0
    end
    name = supplied.fetch('name', config['name'])
    raise AgentVM::Error, 'Invalid VM name' unless name.match?(/\A[a-z][a-z0-9-]{0,39}\z/)
    saved_path = File.join(AgentVM.state_root, name, 'config.json')
    if File.file?(saved_path)
      config = AgentVM.validate(JSON.parse(File.read(saved_path)))
      supplied.each do |key, value|
        if %w[menubar autologin desktop_on_demand source_mode guest_control runtime_mode].include?(key)
          config[key] = value
          next
        elsif key == 'agents'
          raise AgentVM::Error, 'Use vm agents add to change agents on an existing VM.' if config[key] != value
          next
        elsif key == 'credential_relays'
          if config[key] != value && !plan
            puts 'Keeping the saved host-credential choice. Use vm auth set or vm auth relay on/off to change it.'
          end
          next # A skipped key prompt must stay skipped when the original command is rerun.
        elsif key == 'profiles'
          raise AgentVM::Error, 'Use vm profiles add to add tools to an existing VM.' if AgentVM::ProfilePlan.expand(value, config['agents']) != config[key]
          next
        elsif key == 'ui_enabled' && config[key] != value
          raise AgentVM::Error, 'Use vm ui enable or vm ui disable to change guest UI control on an existing VM.'
        elsif key == 'linked_files' && config[key] != value
          raise AgentVM::Error, 'Use vm shares configure --linked-files or --no-linked-files to change an existing VM.'
        elsif key == 'audio_output' && config[key] != value
          raise AgentVM::Error, 'Use vm audio on or vm audio off to change playback on an existing VM.'
        end
        value = File.expand_path(value) if %w[share read_only_share linked_share].include?(key)
        raise AgentVM::Error, "Existing VM has a different #{key}; use a new --name for a different configuration." if config[key] != value
      end
    elsif update
      raise AgentVM::Error, 'An update requires an existing managed VM. Run install.sh without --update to create one.'
    else
      tz = File.realpath('/etc/localtime').split('/zoneinfo/').last rescue 'UTC'
      config['timezone'] = tz unless tz.start_with?('/')
      if supplied['source_vm']
        raise AgentVM::Error, '--from-vm cannot be combined with --fresh or --ipsw.' if supplied['fresh'] || supplied.key?('ipsw')
        source = AgentVM::VM.load(supplied['source_vm'])
        config['credential_relay_cleanup'] = true
        raise AgentVM::Error, 'Source must be a completed managed VM.' unless source.config['phase'] == 'ready'
        %w[user profiles agents disk_gb python].each do |key|
          raise AgentVM::Error, "--from-vm preserves #{key}; change it later with vm commands or choose a pristine installation." if supplied.key?(key) && supplied[key] != source.config[key]
          config[key] = source.config[key]
        end
        %w[cpus memory_gb].each { |key| config[key] = source.config[key] }
        config['share'] = File.join(Dir.home, 'vmshare-' + name) unless supplied.key?('share')
      end
      config.merge!(supplied)
      # Choose convenient defaults only for a new main VM. Resuming an install
      # or updating one must preserve its saved grants, including explicit off.
      config['guest_control'] = true if config['ui_enabled'] && !supplied.key?('guest_control')
      if config['sharing'] == 'hybrid' && !supplied.key?('linked_files')
        explicit_links = supplied.key?('linked_share') || supplied.key?('guest_linked_share')
        config['linked_files'] = explicit_links || AgentVM::MacFUSE.ready?
      end
    end
    config['integrations'] = false unless integrations
    AgentVM.validate(config)
    if plan
      puts JSON.pretty_generate(config)
      puts 'Steps: current Tart + Softnet -> reuse a pristine local OS cache, explicitly clone --from-vm, or create ASIF VM -> provision/configure -> selected tools -> isolated SSH -> verify.'
      puts 'First boot: automatic accounts require macOS 27+ on host and guest; otherwise guided Setup Assistant, then automatic configuration. --setup manual always uses the guided path.'
      puts 'Optional UI/audio build runs in parallel with macOS image preparation; both must finish before first boot.' if config['ui_enabled'] || config['audio_output']
      puts 'Pi setup offers an optional host OpenRouter key. Skipping keeps the relay disabled; configure Pi normally or use vm auth set later.' if config['agents'].include?('pi') && !supplied.key?('credential_relays') && !File.file?(saved_path)
    elsif update
      require_relative 'update'
      vm = AgentVM::VM.new(config)
      checkout = File.expand_path('..', __dir__)
      if supplied.key?('source_mode') && checkout != File.expand_path(vm.file('runtime'))
        vm.config['source_directory'] = checkout
      end
      vm.save
      AgentVM::Update.new(vm).command([])
    else
      unless File.file?(saved_path)
        require_relative 'credentials'
        if config['credential_relays'].include?('openrouter')
          config['credential_relays'] = [] unless AgentVM::HostCredentials.prompt(optional:true)
        elsif config['agents'].include?('pi') && !supplied.key?('credential_relays')
          config['credential_relays'] = ['openrouter'] if AgentVM::HostCredentials.offer_pi
        end
      end
      if config['sharing'] == 'hybrid' && !config['linked_files']
        puts 'Using native writable and read-only folders. The optional linked folder is disabled; no macFUSE installation is needed.'
        puts 'Add it later after enabling host macFUSE: vm stop; vm shares configure --linked-files'
      end
      AgentVM::Installer.new(config, update: update, integrations: integrations).run
    end
    0
  rescue AgentVM::Error, OptionParser::ParseError, ArgumentError => e
    warn "Error: #{e.message}"
    1
  end
end

exit AgentVM::InstallCLI.run(ARGV) if $PROGRAM_NAME == __FILE__
