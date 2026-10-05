#!/usr/bin/ruby
# Second Mac mac-control helper. UI capture and input remain on the host.
require 'json'
require 'net/http'
require 'base64'

module GuestControlClient
  class Error < StandardError; end
  def self.payload(args, input:$stdin)
    op = args.shift || 'help'
    fields = {'status'=>0, 'approve'=>0, 'inspect'=>0, 'screenshot'=>0, 'click'=>2,
              'click-text'=>1, 'key'=>1, 'type'=>0, 'grant'=>nil, 'revoke'=>nil, 'check'=>nil, 'extension'=>2}
    raise Error, 'Unknown command. Use mac-control help.' unless fields.key?(op)
    raise Error, 'Wrong arguments. Use mac-control help.' unless fields[op].nil? ? args.length >= 2 : args.length == fields[op]
    value = {'op'=>op}
    case op
    when 'click' then value.merge!('x'=>Float(args[0]), 'y'=>Float(args[1]))
    when 'click-text' then value['text'] = args.first
    when 'key' then value['key'] = args.first
    when 'type'
      value['text'] = input.read(513)
      raise Error, 'Type accepts at most 512 bytes of printable US-keyboard text.' if value['text'].bytesize > 512
    when 'grant', 'revoke', 'check' then value.merge!('app'=>args.shift, 'permissions'=>args)
    when 'extension' then value.merge!('kind'=>args[0], 'app'=>args[1])
    end
    value
  rescue ArgumentError
    raise Error, 'Invalid coordinate.'
  end
  def self.request(value, path:File.join(Dir.home, '.config/second-mac/control.json'))
    st = File.lstat(path)
    raise Error, 'Unsafe Mac control configuration.' unless st.file? && st.uid == Process.uid && (st.mode & 0077).zero?
    config = JSON.parse(File.read(path))
    port, token = config.values_at('port', 'token')
    raise Error, 'Invalid Mac control configuration.' unless port.is_a?(Integer) && (1024..65535).cover?(port) && token.is_a?(String) && token.match?(/\A[0-9a-f]{64}\z/)
    # Never honor proxy environment variables or send credentials to another URL.
    http = Net::HTTP.new('127.0.0.1', port, nil)
    http.open_timeout, http.read_timeout = 5, 180
    req = Net::HTTP::Post.new('/v1/control', 'Content-Type'=>'application/json', 'Authorization'=>'Bearer ' + token)
    req.body = JSON.generate(value)
    data = +''
    result = nil
    http.request(req) do |response|
      response.read_body do |part|
        data << part
        raise Error, 'Unexpectedly large Mac control response.' if data.bytesize > 32*1024*1024
      end
      result = JSON.parse(data)
      raise Error, 'Invalid Mac control response.' unless result.is_a?(Hash)
      raise Error, result.fetch('error', 'Guest-control request failed.') unless response.code == '200'
    end
    result
  rescue Errno::ENOENT, SystemCallError, IOError, Timeout::Error
    raise Error, 'Mac control is unavailable. Ask your administrator to enable it.'
  rescue JSON::ParserError
    raise Error, 'Invalid Mac control response or configuration.'
  end
  def self.password(args, path:'/etc/agent-vm/admin-password')
    require '/usr/local/libexec/agent-vm/core' unless defined?(AgentVM.password_command)
    metadata = File.lstat(path)
    unless metadata.file? && metadata.uid == Process.uid && (metadata.mode & 0077).zero?
      raise Error, 'Password file is unavailable or has unsafe permissions; ask your administrator to repair the configuration.'
    end
    AgentVM.password_command(File.read(path).strip, args, guest:true)
  rescue AgentVM::Error => error
    raise Error, error.message
  end
  def self.camera(args)
    unless [[], ['status'], ['help']].include?(args)
      raise Error, 'Use mac-control camera status. Video input is enabled separately by your administrator.'
    end
    path = File.join(Dir.home, '.local/state/second-mac/camera.json')
    active = false
    if File.file?(path) && !File.symlink?(path)
      state = JSON.parse(File.read(path))
      pid = state.fetch('pid')
      begin
        active = pid.is_a?(Integer) && pid > 0 && Process.kill(0, pid) == 1
        lock = File.join(File.dirname(path), 'camera.lock')
        active &&= File.file?(lock) && !File.symlink?(lock) && File.open(lock, 'r') { |file| !file.flock(File::LOCK_SH|File::LOCK_NB) }
      rescue Errno::ESRCH
      end
    end
    puts "OBS video receiver: #{active ? 'running' : 'stopped'}. Select OBS Virtual Camera in the consuming app."
    puts 'Video and microphone inputs are enabled separately by your administrator.'
  end
  def self.main(args)
    if args.empty? || %w[help --help -h].include?(args.first)
      puts 'mac-control: control this Mac\'s UI and app permissions. No LLM or cloud service required.'
      puts 'mac-control status | approve | inspect | screenshot > screen.png'
      puts 'mac-control click X Y | click-text LABEL | key cmd+SHORTCUT | type < text'
      puts 'mac-control check|grant|revoke /Applications/App.app PERMISSION...'
      puts 'mac-control extension camera|network|filesystem EXACT_APP_LABEL'
      puts 'Permissions: accessibility, screen-recording, full-disk, input-monitoring, camera, microphone, documents, downloads, all.'
      puts 'Example: mac-control grant /Applications/OBS.app screen-recording'
      puts 'Your administrator must enable Mac control. Supported grants use Settings with SIP on; direct grants need SIP already off.'
      puts 'Camera/microphone permissions must first be requested by the app. This command cannot change SIP or enable media inputs.'
      puts 'mac-control password [--copy | --show | --local] — copy the account password; --show requires an interactive terminal.'
      puts 'Over SSH, password copy targets your SSH terminal clipboard; --local selects this Mac\'s desktop clipboard.'
      puts 'mac-control camera status — inspect the optional OBS video receiver.'
      puts 'mac-control doctor — check managed services, shared files, DNS and privacy settings.'
      puts 'Password, camera status and doctor work without control access. Install software with ordinary tools such as Homebrew.'
      return
    end
    return password(args.drop(1)) if args.first == 'password'
    return camera(args.drop(1)) if args.first == 'camera'
    if args == ['doctor']
      exec('/usr/bin/ruby', File.join(Dir.home, '.local/share/agent-vm/doctor.rb'))
    end
    value = payload(args)
    result = request(value)
    if value['op'] == 'screenshot'
      $stdout.binmode
      $stdout.write(Base64.strict_decode64(result.fetch('png')))
    elsif result['output']
      puts result['output']
    else
      puts JSON.pretty_generate(result)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    GuestControlClient.main(ARGV)
  rescue GuestControlClient::Error, SystemCallError, JSON::ParserError => error
    warn "Error: #{error.message}"
    exit 1
  end
end
