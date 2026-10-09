# Shared, side-effect-free syntax and validation for guest mac-control and vm ui.
require 'json'
require 'base64'
require 'securerandom'

module MacControlCommands
  class Error < StandardError; end
  TEXT_LIMIT = 4096
  POINTER = %w[click move drag scroll].freeze
  FIELDS = {'click'=>%w[x y button count], 'move'=>%w[x y],
            'drag'=>%w[x y to_x to_y duration], 'scroll'=>%w[x y dx dy]}.freeze
  HELP = {
    'click'=>'click X Y [--button left|right|middle] [--count 1|2|3]',
    'move'=>'move X Y',
    'drag'=>'drag X Y TO_X TO_Y [--duration SECONDS] (0.1–5; default 0.6)',
    'scroll'=>'scroll up|down|left|right [PIXELS] [--at X Y] (default 320 pixels at 512 384)',
    'type'=>'type [TEXT] (or stdin; US keyboard, ASCII including tabs/newlines; 4096 bytes)',
    'paste'=>'paste [TEXT] (or stdin; UTF-8; replaces only this Mac’s clipboard and sends Cmd-V)',
    'screenshot'=>'screenshot [FILE.png|-] (PNG to a file or redirected stdout)',
    'inspect'=>'inspect (OCR text and centers in the same coordinates as screenshot)',
    'key'=>'key SHORTCUT [--hold-ms MILLISECONDS] (10–5000; default 80 on an updated viewer)',
    'click-text'=>'click-text LABEL (one exact, case-insensitive OCR match)',
    'capabilities'=>'capabilities (running viewer operations and coordinate dimensions)'
  }.freeze
  def self.key(args)
    args, opts = options(args.dup, '--hold-ms'=>1)
    raise Error, "Usage: #{HELP.fetch('key')}" unless args.length == 1
    value = {'op'=>'key', 'key'=>args.first}
    value['hold_ms'] = Integer(opts['--hold-ms'][0], 10) if opts.key?('--hold-ms')
    validate_key(value)
    value
  rescue ArgumentError
    raise Error, 'Key hold must be an integer from 10 to 5000 milliseconds.'
  end
  def self.validate_key(value)
    fields = %w[op key] + (value.key?('hold_ms') ? ['hold_ms'] : [])
    raise Error, 'Unexpected or missing key arguments.' unless value.keys.sort == fields.sort
    key = value['key']
    raise Error, 'Expected a nonempty shortcut of at most 512 bytes.' unless key.is_a?(String) && key.valid_encoding? && key.bytesize.between?(1,512) && !key.match?(/[\x00-\x1f\x7f]/)
    if value.key?('hold_ms')
      ms = value['hold_ms']
      raise Error, 'Key hold must be an integer from 10 to 5000 milliseconds.' unless ms.is_a?(Integer) && ms.between?(10,5000)
    end
  end
  def self.response_timeout(value)
    # Typing includes an 80 ms native hold and the existing 150 ms settling
    # pause per character. Do not time out and invite replay of a partial edit.
    return 180 unless value['op'] == 'type' && value['text'].is_a?(String)
    [180, 60 + [value['text'].bytesize, TEXT_LIMIT].min * 0.35].max.ceil
  end
  def self.number(text)
    value = Float(text)
    raise Error, 'Expected a finite number.' unless value.finite?
    value
  rescue ArgumentError, TypeError
    raise Error, 'Expected a finite number.'
  end
  def self.options(args, allowed)
    values, positional = {}, []
    until args.empty?
      word = args.shift
      if allowed.key?(word)
        count = allowed.fetch(word)
        raise Error, "Missing value for #{word}." if args.length < count || values.key?(word)
        values[word] = args.shift(count)
      else
        positional << word
      end
    end
    [positional, values]
  end
  def self.pointer(op, args)
    allowed = {'click'=>{'--button'=>1, '--count'=>1}, 'drag'=>{'--duration'=>1}, 'scroll'=>{'--at'=>2}}
    args, opts = options(args.dup, allowed.fetch(op, {}))
    count = {'click'=>[2], 'move'=>[2], 'drag'=>[4], 'scroll'=>[1,2]}.fetch(op)
    raise Error, "Usage: #{HELP.fetch(op)}" unless count.include?(args.length)
    value = {'op'=>op}
    if op == 'scroll'
      direction = {'up'=>[0,-1], 'down'=>[0,1], 'left'=>[-1,0], 'right'=>[1,0]}[args[0]]
      raise Error, 'Scroll direction must be up, down, left or right.' unless direction
      amount = number(args[1] || 320)
      raise Error, 'Scroll distance must be 1–4096 pixels.' unless amount.between?(1,4096)
      x, y = (opts['--at'] || [512,384]).map { |v| number(v) }
      value.merge!('x'=>x, 'y'=>y, 'dx'=>direction[0]*amount, 'dy'=>direction[1]*amount)
    else
      names = op == 'drag' ? %w[x y to_x to_y] : %w[x y]
      names.zip(args).each { |name, v| value[name] = number(v) }
      value.merge!('button'=>(opts['--button'] || ['left'])[0], 'count'=>Integer((opts['--count'] || ['1'])[0], 10)) if op == 'click'
      value['duration'] = number((opts['--duration'] || [0.6])[0]) if op == 'drag'
    end
    validate_pointer(value)
    value
  rescue ArgumentError
    raise Error, 'Click count must be 1, 2 or 3.'
  end
  def self.validate_pointer(value)
    op = value['op']
    fields = FIELDS.fetch(op)
    # Old clients send only x/y for a left click.
    fields = %w[x y] if op == 'click' && value.keys.sort == %w[op x y]
    raise Error, 'Unexpected or missing pointer arguments.' unless value.keys.sort == (fields + ['op']).sort
    pairs = op == 'drag' ? [%w[x y], %w[to_x to_y]] : [%w[x y]]
    pairs.each do |names|
      names.zip([1024,768]).each do |name, bound|
        n = value[name]
        raise Error, 'Coordinates must lie inside the 1024×768 screenshot.' unless n.is_a?(Numeric) && n.finite? && n >= 0 && n < bound
      end
    end
    if op == 'click'
      raise Error, 'Choose left, right or middle and a click count of 1–3.' unless %w[left right middle].include?(value.fetch('button','left')) && value.fetch('count',1).is_a?(Integer) && (1..3).cover?(value.fetch('count',1))
    elsif op == 'drag'
      n = value['duration']
      raise Error, 'Drag duration must be 0.1–5 seconds.' unless n.is_a?(Numeric) && n.finite? && n.between?(0.1,5)
    elsif op == 'scroll'
      raise Error, 'Scroll deltas must be finite and at most 4096 pixels.' unless %w[dx dy].all? { |k| value[k].is_a?(Numeric) && value[k].finite? && value[k].abs <= 4096 } && (value['dx'] != 0 || value['dy'] != 0)
    end
  end
  def self.text(args, input:$stdin, unicode:false)
    args = args.drop(1) if args.first == '--'
    raise Error, 'Pass one quoted text argument, or supply text on stdin.' unless args.length <= 1
    raise Error, 'Pass text as an argument or pipe it on stdin.' if args.empty? && input.tty?
    value = args.empty? ? input.read(TEXT_LIMIT + 1) : args.first.dup
    value.force_encoding(Encoding::UTF_8)
    validate_text(value, unicode:unicode)
    value
  end
  def self.validate_text(value, unicode:false)
    raise Error, 'Text must be valid UTF-8 and 1–4096 bytes.' unless value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1,TEXT_LIMIT)
    pattern = unicode ? /[\x00-\x08\x0b-\x1f\x7f]/ : /[^\x09\x0a\x20-\x7e]/
    raise Error, unicode ? 'Text contains unsupported control characters.' : 'Type uses the US keyboard. Use mac-control paste for Unicode; tabs and newlines are supported.' if value.match?(pattern)
  end
  def self.screenshot(result, path:nil, output:$stdout)
    png = Base64.strict_decode64(result.fetch('png'))
    raise Error, 'Invalid screenshot response.' unless png.start_with?("\x89PNG\r\n\x1a\n".b)
    if path.nil? || path == '-'
      raise Error, 'Choose a PNG path or redirect stdout: mac-control screenshot screen.png' if output.tty?
      output.binmode
      output.write(png)
      return
    end
    path = File.expand_path(path)
    raise Error, 'Screenshot destination is a symlink.' if File.symlink?(path)
    temporary = path + '.' + SecureRandom.hex(8)
    begin
      File.open(temporary, File::WRONLY|File::CREAT|File::EXCL, 0600) { |f| f.write(png) }
      File.rename(temporary, path)
    ensure
      File.unlink(temporary) if File.exist?(temporary)
    end
    output.puts JSON.generate('path'=>path, 'width'=>result['width'], 'height'=>result['height'])
  rescue ArgumentError, KeyError
    raise Error, 'Invalid screenshot response.'
  end
end
