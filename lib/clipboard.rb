require_relative 'core'

module AgentVM
  # One host-initiated snapshot through SSH, never a service or guest grant.
  class Clipboard
    MAX_TEXT = 1024 * 1024
    MAX_RESPONSE = MAX_TEXT * 6 + 1024 # Worst-case JSON string escaping.
    SCRIPT = File.read(File.join(__dir__, 'clipboard.js')).freeze

    def initialize(vm); @vm = vm; end

    def command(args)
      unless [%w[to-guest], %w[to-host]].include?(args)
        raise Error, 'Usage: vm clipboard to-guest | to-host (one-time plain text copy)'
      end
      prepare
      to_guest = args.first == 'to-guest'
      source = to_guest ? 'host' : 'guest'
      destination = to_guest ? 'guest' : 'host'
      payload = decode(capture(endpoint(source, 'read')))
      case payload
      when {'error'=>'no-text'}
        raise Error, "The #{source} clipboard has no plain text; the #{destination} clipboard was kept."
      when {'error'=>'too-large'}
        raise Error, 'Clipboard text exceeds the 1 MiB limit; use vm cp for large content.'
      end
      text = payload['text']
      unless payload.keys == ['text'] && text.is_a?(String) && text.valid_encoding? && text.bytesize <= MAX_TEXT
        raise Error, 'Invalid clipboard response; the destination clipboard was kept.'
      end
      write_text(destination, text)
      puts "Copied plain text from #{source} to #{destination}. Press Command-V in the destination app."
    end

    def copy_password
      prepare
      write_text('guest', @vm.password)
      puts 'Guest password copied to the guest clipboard. Press Command-V in the guest password field.'
    end

    private

    def prepare
      raise Error, 'Start or resume the guest first; clipboard copies never start a VM.' unless @vm.running?
      # Check before reading either clipboard. An SSH login alone does not
      # establish the intended account's graphical pasteboard session.
      account = capture(remote('/usr/bin/stat', '-f', '%Su', '/dev/console'), limit:256).strip
      unless account == @vm.config.fetch('user')
        raise Error, 'Log into the configured guest desktop account before copying its clipboard.'
      end
    end

    def write_text(destination, text)
      result = decode(capture(endpoint(destination, 'write'), input:JSON.generate('text'=>text), limit:1024))
      raise Error, 'The destination clipboard could not be written.' unless result == {'ok'=>true}
    end

    def endpoint(side, operation)
      args = ['/usr/bin/osascript', '-l', 'JavaScript', '-e', SCRIPT, operation]
      side == 'guest' ? remote(*args) : args
    end

    def remote(*args)
      [*@vm.ssh_args, '-T', @vm.name, Shellwords.join(args)]
    end

    def decode(value)
      result = JSON.parse(value.force_encoding(Encoding::UTF_8))
      raise Error, 'Invalid clipboard response; no clipboard contents were logged.' unless result.is_a?(Hash)
      result
    rescue JSON::ParserError, EncodingError
      raise Error, 'Invalid clipboard response; no clipboard contents were logged.'
    end

    # Do not use the general command logger: a compromised guest can echo
    # clipboard data on either stream, including on failure. Bound its output,
    # discard stderr, and never include subprocess output in an error.
    def capture(args, input:'', limit:MAX_RESPONSE, timeout:15)
      output = ''.b
      Open3.popen2(*args, err:File::NULL, pgroup:true) do |stdin, stdout, waiter|
        stdin.binmode
        stdout.binmode
        writer = Thread.new do
          begin
            stdin.write(input)
          rescue Errno::EPIPE, IOError
          ensure
            stdin.close rescue nil
          end
        end
        begin
          Timeout.timeout(timeout) do
            begin
              loop do
                output << stdout.readpartial([16384, limit + 1 - output.bytesize].min)
                raise Error, 'Clipboard response exceeded the transfer limit.' if output.bytesize > limit
              end
            rescue EOFError
            end
            writer.join
            unless waiter.value.success?
              raise Error, 'Clipboard transfer failed. Check the guest login and SSH connection, then retry.'
            end
          end
        ensure
          if waiter.alive?
            Process.kill('TERM', -waiter.pid) rescue nil
            waiter.join(1)
            Process.kill('KILL', -waiter.pid) rescue nil if waiter.alive?
          end
          [stdin, stdout].each { |stream| stream.close rescue nil }
          writer.join(1)
          writer.kill if writer.alive?
        end
      end
      output
    rescue Timeout::Error
      raise Error, 'Clipboard transfer timed out; check the guest login and retry.'
    rescue SystemCallError, IOError
      raise Error, 'Clipboard transport is unavailable; check the guest connection and retry.'
    end
  end
end
