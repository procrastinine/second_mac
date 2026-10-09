# Native integration check. Uses private named pasteboards on both Macs;
# never reads or replaces either user's ordinary clipboard.
# Run: ruby tests/clipboard-check.rb [--guest]
require_relative '../lib/clipboard'
require 'etc'

class NamedClipboardCheck < AgentVM::Clipboard
  def initialize(vm, guest:)
    super(vm)
    @guest = guest
    @names = %w[host guest].to_h { |side| [side, "second-mac-test-#{SecureRandom.hex(16)}-#{side}"] }
  end
  def remote(*args)
    @guest ? super : args
  end
  def endpoint(side, operation)
    script = SCRIPT.sub('$.NSPasteboard.generalPasteboard', board(side))
    args = ['/usr/bin/osascript', '-l', 'JavaScript', '-e', script, operation]
    side == 'guest' ? remote(*args) : args
  end
  def board(side)
    '$.NSPasteboard.pasteboardWithName(' + JSON.generate(@names.fetch(side)) + ')'
  end
  def script(side, body)
    args = ['/usr/bin/osascript', '-l', 'JavaScript', '-e', "ObjC.import('AppKit'); " + body]
    capture(side == 'guest' ? remote(*args) : args)
  end
  def seed(side, text)
    result = decode(capture(endpoint(side, 'write'), input:JSON.generate('text'=>text)))
    raise 'Fixture write failed' unless result == {'ok'=>true}
  end
  def read(side)
    decode(capture(endpoint(side, 'read'))).fetch('text')
  end
  def check(value, label)
    raise label unless value
    puts 'PASS: ' + label
  end
  def verify
    before = %w[host guest].to_h { |side| [side, script(side, '$.NSPasteboard.generalPasteboard.changeCount')] }
    text = "clipboard fixture 中文 🔒\n{\\rtf1 literal} $(false) `false`\n\n"
    seed('host', text)
    seed('guest', 'old guest')
    command(['to-guest'])
    check(read('guest') == text, 'host to guest preserves Unicode, literal text and trailing newlines')
    seed('host', 'later host text')
    check(read('guest') == text, 'later host clipboard changes are not shared')
    seed('guest', "guest result\n\n")
    check(read('host') == 'later host text', 'guest changes cannot overwrite host clipboard')
    command(['to-host'])
    check(read('host') == "guest result\n\n", 'guest to host requires an explicit copy')
    @vm.define_singleton_method(:password) { 'synthetic-password-for-clipboard-test' }
    copy_password
    check(read('guest') == 'synthetic-password-for-clipboard-test', 'password action writes directly to guest')
    check(read('host') == "guest result\n\n", 'password action leaves host clipboard alone')
    script('guest', board('guest') + '.clearContents;')
    begin
      command(['to-host'])
      raise 'Empty pasteboard was incorrectly accepted'
    rescue AgentVM::Error => error
      check(error.message.include?('no plain text'), 'no-text clipboard produces a safe error')
    end
    check(read('host') == "guest result\n\n", 'failed source read preserves destination')
    %w[host guest].each do |side|
      check(script(side, '$.NSPasteboard.generalPasteboard.changeCount') == before.fetch(side), side + ' ordinary clipboard was untouched')
    end
  ensure
    %w[host guest].each { |side| script(side, board(side) + '.releaseGlobally;') }
  end
end

raise 'Usage: ruby tests/clipboard-check.rb [--guest]' unless [[], ['--guest']].include?(ARGV)
guest = ARGV == ['--guest']
vm = if guest
       AgentVM::VM.load
     else
       Struct.new(:config, :running?).new({'user'=>Etc.getpwuid(Process.uid).name}, true)
     end
NamedClipboardCheck.new(vm, guest:guest).verify
