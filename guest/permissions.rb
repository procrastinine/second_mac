#!/usr/bin/ruby
require 'json'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'etc'

module GuestPermissions
  ROOT = '/var/db/second-mac-permissions'.freeze
  SERVICES = {
    'documents'=>'SystemPolicyDocumentsFolder', 'desktop'=>'SystemPolicyDesktopFolder',
    'downloads'=>'SystemPolicyDownloadsFolder', 'network-volumes'=>'SystemPolicyNetworkVolumes',
    'removable-volumes'=>'SystemPolicyRemovableVolumes', 'full-disk'=>'SystemPolicyAllFiles',
    'accessibility'=>'Accessibility', 'screen-recording'=>'ScreenCapture',
    'input-monitoring'=>'ListenEvent', 'camera'=>'Camera', 'microphone'=>'Microphone',
    'speech'=>'SpeechRecognition', 'contacts'=>'AddressBook', 'calendar'=>'Calendar',
    'reminders'=>'Reminders', 'photos'=>'Photos'
  }.freeze
  SYSTEM_SERVICES = %w[SystemPolicyAllFiles Accessibility ScreenCapture ListenEvent PostEvent].freeze
  class Error < StandardError; end
  def self.run(*args, input:nil)
    out, status = Open3.capture2e(*args, stdin_data:input)
    raise Error, out.strip.empty? ? "Failed: #{File.basename(args.first)}" : out.strip unless status.success?
    out
  end
  def self.guard!
    raise Error, 'This helper runs only inside a configured Apple VM.' unless run('/usr/sbin/sysctl', '-n', 'hw.model').strip.start_with?('VirtualMac') && File.file?('/etc/agent-vm/config.json')
    raise Error, 'Run this command with guest sudo or vm permissions on the host.' unless Process.uid.zero?
  end
  def self.account
    Etc.getpwnam(JSON.parse(File.read('/etc/agent-vm/config.json')).fetch('user'))
  end
  def self.databases
    return @databases if @databases
    user = account
    legacy = File.join(user.dir, 'Library/Application Support/com.apple.TCC/TCC.db')
    # macOS 27 moves user TCC into a ProtectedSystem container. Ask the running
    # daemon for this exact UID; never guess a container UUID or another user's
    # database, and never create a replacement store.
    output, status = Open3.capture2e('/usr/sbin/lsof', '-a', '-c', 'tccd', '-u', user.uid.to_s, '-Fn')
    current = status.success? ? user_database(output, user.dir) : nil
    @databases = ['/Library/Application Support/com.apple.TCC/TCC.db', current || legacy]
  end
  def self.user_database(open_files, home)
    candidates = open_files.lines.map do |line|
      path = line.chomp.delete_prefix('n')
      next unless line.start_with?('n/') && path.end_with?('/com.apple.TCC/TCC.db')
      next unless path.start_with?(home + '/Library/', '/private/var/containers/Data/ProtectedSystem/')
      path
    end.compact.uniq
    raise Error, 'More than one active user permission database; refusing an ambiguous grant.' if candidates.length > 1
    candidates.first
  end
  def self.sip_off?
    run('/usr/bin/csrutil', 'status').strip == 'System Integrity Protection status: disabled.'
  end
  def self.writable!
    raise Error, 'Direct grants require guest SIP disabled. On the host run vm sip off; the host SIP policy is never changed.' unless sip_off?
  end
  def self.sql(value)
    "'#{value.to_s.gsub("'", "''")}'"
  end
  def self.query(db, statement)
    raise Error, 'Guest TCC database is not initialized. Open the affected app in the guest desktop and request a permission once.' unless File.file?(db) && !File.symlink?(db)
    run('/usr/bin/sqlite3', '-batch', '-cmd', '.timeout 5000', db, statement)
  end
  def self.columns(db)
    result = query(db, 'PRAGMA table_info(access);').lines.map { |line| line.split('|')[1] }
    raise Error, 'Unsupported TCC database schema; no changes made.' unless (%w[service client client_type auth_value auth_reason auth_version csreq last_modified] - result).empty?
    result
  end
  def self.prepare(targets = databases)
    FileUtils.mkdir_p(ROOT, mode:0700)
    raise Error, 'Unsafe permission state directory.' if File.symlink?(ROOT) || File.stat(ROOT).uid != 0
    File.chmod(0700, ROOT)
    targets.each do |db|
      columns(db)
      index = databases.index(db)
      raise Error, 'Unrecognized guest permission database.' unless index
      backup = File.join(ROOT, "before-first-grant-#{index}.db")
      query(db, '.backup ' + sql(backup)) unless File.exist?(backup)
      File.chmod(0600, backup)
    end
  end
  def self.identity(path)
    path = File.realpath(path)
    bundle = File.directory?(path) && path.end_with?('.app')
    raise Error, 'Choose an installed .app directory or executable path inside the guest.' unless bundle || (File.file?(path) && File.executable?(path))
    run('/usr/bin/codesign', '--verify', path)
    description = run('/usr/bin/codesign', '-d', '-r-', path)
    # codesign prefixes synthesized (including ad-hoc) requirements with '# '.
    requirement = description[/^(?:#\s*)?designated => (.+)$/, 1]
    raise Error, 'Could not read the executable code identity.' unless requirement
    client = bundle ? run('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleIdentifier', File.join(path, 'Contents/Info.plist')).strip : path
    csreq = nil
    Dir.mktmpdir('second-mac-csreq-') do |dir|
      text, binary = File.join(dir, 'requirement'), File.join(dir, 'binary')
      File.write(text, requirement)
      run('/usr/bin/csreq', '-r', text, '-b', binary)
      csreq = File.binread(binary).unpack1('H*')
    end
    [client, bundle ? 0 : 1, csreq]
  end
  def self.check(path, names)
    client, kind, = identity(path)
    chosen = names.empty? || names == ['all'] ? SERVICES.keys : names
    errors = {}
    states = chosen.each_with_object({}) do |name, result|
      target = name.start_with?('apple-events:') ? name.delete_prefix('apple-events:') : 'UNUSED'
      service = name.start_with?('apple-events:') ? 'AppleEvents' : SERVICES.fetch(name) { raise Error, 'Unknown permission: ' + name }
      db = databases[SYSTEM_SERVICES.include?(service) ? 0 : 1]
      begin
        value = if File.file?(db)
          query(db, "SELECT auth_value FROM access WHERE service=#{sql('kTCCService'+service)} AND client=#{sql(client)} AND client_type=#{kind} AND indirect_object_identifier=#{sql(target)};").strip
        end
        result[name] = value && !value.empty? ? Integer(value) : nil
      rescue Error, Errno::EACCES, Errno::EPERM
        # SIP-on macOS can deny even root read access to the per-user store.
        # An unreadable record is neither a missing grant nor a denial.
        result[name] = 'unavailable'
        errors[name] = 'Permission records are not readable under the current system policy. Check Settings or the app.'
      end
    end
    {'client'=>client, 'permissions'=>states, 'errors'=>errors}
  end
  def self.grant(path, services, allow:true)
    writable!
    chosen = services.empty? || services == ['all'] ? SERVICES.values : services.map do |name|
      SERVICES.fetch(name) { raise Error, 'Unknown permission. Choices: ' + SERVICES.keys.join(', ') + ', all, apple-events:TARGET_BUNDLE_ID' } unless name.start_with?('apple-events:')
      name.start_with?('apple-events:') ? name : SERVICES.fetch(name)
    end
    client, kind, csreq = identity(path)
    targets = chosen.map { |service| databases[SYSTEM_SERVICES.include?(service) ? 0 : 1] }.uniq
    targets.each { |db| columns(db) } # Validate every target before changing any.
    prepare(targets)
    chosen.each do |service|
      target = service.start_with?('apple-events:') ? service.delete_prefix('apple-events:') : 'UNUSED'
      raise Error, 'Apple Events needs a target bundle ID.' if target.empty? || target.match?(/[\x00-\x1f]/)
      service = 'AppleEvents' if service.start_with?('apple-events:')
      db = databases[SYSTEM_SERVICES.include?(service) ? 0 : 1]
      row = {'service'=>sql('kTCCService' + service), 'client'=>sql(client), 'client_type'=>kind,
             'auth_value'=>allow ? 2 : 0, 'auth_reason'=>4, 'auth_version'=>1, 'csreq'=>"X'#{csreq}'",
             'policy_id'=>'NULL', 'indirect_object_identifier_type'=>target == 'UNUSED' ? 'NULL' : 0,
             'indirect_object_identifier'=>sql(target), 'indirect_object_code_identity'=>'NULL',
             'flags'=>0, 'last_modified'=>Time.now.to_i, 'pid'=>0, 'pid_version'=>0,
             'boot_uuid'=>sql('UNUSED'), 'last_reminded'=>Time.now.to_i}
      available = columns(db)
      row.select! { |column, _| available.include?(column) }
      query(db, "INSERT OR REPLACE INTO access (#{row.keys.join(',')}) VALUES (#{row.values.join(',')});")
      actual = query(db, "SELECT auth_value FROM access WHERE service=#{row['service']} AND client=#{sql(client)} AND client_type=#{kind} AND indirect_object_identifier=#{sql(target)};").strip
      raise Error, 'TCC grant did not persist.' unless actual == (allow ? '2' : '0')
    end
    reload
    puts "Recorded #{allow ? 'allow' : 'deny'} for #{chosen.length} permissions for #{client}. Restart the affected app if it cached a decision."
    puts 'SIP-off macOS can bypass protected-folder denials; restore SIP for those restrictions to apply.' unless allow
  end
  def self.reload
    # Each per-user daemon restarts automatically and re-reads the database.
    system('/usr/bin/killall', 'tccd', out:File::NULL, err:File::NULL)
  end
  def self.auto_pass
    return 0 unless sip_off?
    existing = databases.select { |db| File.file?(db) }
    prepare(existing)
    count = 0
    existing.each do |db|
      columns(db)
      # Only existing requests are approved. We neither invent clients nor
      # weaken the host, Gatekeeper, FileVault, or kernel-extension consent.
      filter = "auth_value IN (0,1,3) AND service LIKE 'kTCCService%'"
      count += query(db, "SELECT count(*) FROM access WHERE #{filter};").to_i
      query(db, "UPDATE access SET auth_value=2, auth_reason=4, last_modified=#{Time.now.to_i} WHERE #{filter};")
    end
    reload if count > 0
    count
  end
  def self.main(args)
    guard!
    action = args.shift || 'status'
    case action
    when 'status'
      puts run('/usr/bin/csrutil', 'status')
      puts 'Available: grant|revoke /guest/path/to/App.app [PERMISSION...]'
      puts 'Permissions: ' + SERVICES.keys.join(', ') + ', all, apple-events:TARGET_BUNDLE_ID'
    when 'grant', 'revoke'
      path = args.shift || raise(Error, 'An app or executable path inside the guest is required.')
      grant(path, args, allow:action == 'grant')
    when 'check'
      path = args.shift || raise(Error, 'An app or executable path inside the guest is required.')
      puts JSON.generate(check(path, args))
    when 'approve-recorded'
      count=auto_pass
      puts "Approved #{count} recorded guest permissions." if count > 0
    else raise Error,
 'Usage: vm permissions [status|grant|revoke]'
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    GuestPermissions.main(ARGV)
  rescue GuestPermissions::Error, SystemCallError => error
    warn "Error: #{error.message}"
    exit 1
  end
end
