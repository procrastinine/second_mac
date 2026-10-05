require_relative 'command-catalog'
require 'shellwords'

module AgentVM
  # Local-only completion. Deliberately does not load core.rb or a VM instance:
  # a Tab must not run Tart, SSH, service probes, or configuration migrations.
  module Completion
    module_function

    def state_root
      File.expand_path(ENV.fetch('AGENT_VM_HOME', '~/.local/share/agent-vm'))
    end

    def read_json(path)
      return {} unless File.file?(path) && !File.symlink?(path) && File.size(path) < 1_048_576
      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : {}
    rescue SystemCallError, JSON::ParserError, EncodingError
      {}
    end

    def valid_name?(name)
      name.is_a?(String) && name.match?(/\A[a-z][a-z0-9-]{0,39}\z/)
    end

    def records
      Dir.children(state_root).sort.map do |name|
        next unless valid_name?(name) && !File.symlink?(File.join(state_root, name))
        data = read_json(File.join(state_root, name, 'config.json'))
        data if data['name'] == name
      end.compact
    rescue SystemCallError
      []
    end

    def default_name
      path = File.join(state_root, 'default')
      name = File.read(path, 80).strip if File.file?(path) && !File.symlink?(path)
      valid_name?(name) ? name : 'agent-box'
    rescue SystemCallError
      'agent-box'
    end

    def throwaways
      records.select { |data| data['throwaway'].is_a?(Hash) && data['throwaway']['id'].is_a?(String) && data['throwaway']['id'].match?(/\A[0-9a-f]{8}\z/) }
    end

    def filenames(current, directories:false)
      return [] if current.start_with?(':') || current.include?("\n")
      prefix = current.include?('/') ? current[0..current.rindex('/')] : ''
      prefix = '~/' if current == '~'
      directory = File.expand_path(prefix.empty? ? '.' : prefix)
      Dir.children(directory).sort.map do |entry|
        next if entry.start_with?('.') && !File.basename(current).start_with?('.')
        path = File.join(directory, entry)
        is_directory = File.directory?(path)
        next if directories && !is_directory
        prefix + entry + (is_directory ? '/' : '')
      end.compact
    rescue SystemCallError, ArgumentError
      []
    end

    def candidates(kind, current, name)
      case kind
      when Array
        # Profile/agent handlers accept both separate words and comma lists.
        prefix = current.include?(',') ? current[0..current.rindex(',')] : ''
        (kind - prefix.split(',')).map { |value| prefix + value }
      when :vm then records.map { |data| data['name'] }
      when :throwaway then throwaways.map { |data| data['throwaway']['id'] }
      when :snapshot
        return [] unless valid_name?(name)
        root = File.join(state_root, name, 'snapshots')
        return [] if File.symlink?(File.join(state_root, name)) || File.symlink?(root)
        Dir.children(root).sort.select do |entry|
          entry.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}\z/) &&
            !File.symlink?(File.join(root, entry)) && !File.symlink?(File.join(root, entry, 'manifest.json')) && File.file?(File.join(root, entry, 'manifest.json'))
        end
      when :host_port, :guest_port
        return [] unless valid_name?(name) && !File.symlink?(File.join(state_root, name))
        data = read_json(File.join(state_root, name, 'config.json'))
        Array(data['ports']).select { |port| port.is_a?(Hash) && port['direction'] == kind.to_s.delete_suffix('_port') }
          .map { |port| port['source'].to_s }.select { |port| port.match?(/\A\d{1,5}\z/) }
      when :file then filenames(current)
      when :directory then filenames(current, directories:true)
      else []
      end
    rescue SystemCallError
      []
    end

    def complete(words)
      args = words.dup
      current = args.pop.to_s
      name = default_name
      if args.first == '--name'
        return filter(candidates(:vm, current, name), current) if args.length == 1
        args.shift
        name = args.shift
      end
      if args.empty?
        return filter(CommandCatalog.children.map(&:path) + %w[--name --help -h], current)
      end
      help_mode = args.first == 'help'
      args.shift if help_mode
      path = ''
      node = nil
      position = 0
      leading = 0
      until args.empty?
        word = args.shift
        return [] if word == '--'
        if node
          option, inline = word.split('=', 2)
          spec = CommandCatalog.option_specs(node)[option]
          if spec
            if spec.first && inline.nil?
              return filter(candidates(node.values[option], current, name), current) if args.empty?
              args.shift
            end
            next
          end
          if leading > 0 && !help_mode
            copy = throwaways.find { |data| data['throwaway']['id'] == word }
            name = copy['name'] if copy
            leading -= 1
            next
          end
        end
        child_path = [path, word].reject(&:empty?).join(' ')
        if (child = CommandCatalog::COMMANDS[child_path]) && (position.zero? || help_mode)
          node, path, position, leading = child, child_path, 0, child.leading
        elsif node && !help_mode
          return [] if node.passthrough
          position += 1
        else
          return []
        end
      end
      children = CommandCatalog.children(path)
      return filter(children.map { |child| child.path.split.last }, current) if help_mode
      return filter(candidates(:throwaway, current, name) + %w[--help -h], current) if leading > 0
      return [] unless node
      if current.start_with?('-')
        option, inline = current.split('=', 2)
        if inline && CommandCatalog.option_specs(node).dig(option, 0)
          return filter(candidates(node.values[option], inline, name).map { |value| option + '=' + value }, current)
        end
        return filter(CommandCatalog.option_specs(node).keys + %w[--help -h], current)
      end
      choices = position.zero? ? children.map { |child| child.path.split.last } : []
      kind = node.arguments[position] || (node.repeat ? node.arguments.last : nil)
      choices += candidates(kind, current, name)
      filter(choices, current)
    rescue SystemCallError, ArgumentError, EncodingError
      []
    end

    def filter(values, current)
      values.uniq.select { |value| value.start_with?(current) && !value.match?(/[\x00-\x1f\x7f]/) }
    end

    def bash_complete(words, wordbreaks:':=')
      # COMP_WORDS can keep '=' inside a word (Bash 3.2) or split it out.
      # Readline still replaces only the fragment after its last word break.
      # Join assignments for lookup, then trim the reply using COMP_WORDBREAKS.
      return [] if words.last(2).include?(':') || words.last.to_s.start_with?(':')
      merged = []
      words.each do |word|
        if word == '=' && !merged.empty?
          merged[-1] += '='
        elsif !merged.empty? && merged.last.end_with?('=')
          merged[-1] += word
        else
          merged << word
        end
      end
      replies = complete(merged)
      if merged.last.to_s.include?('=') && wordbreaks.include?('=')
        replies.map { |value| value.rpartition('=').last }
      else
        replies
      end
    end

    def shell(shell, backend:File.join(__dir__, 'completion.rb'), root:state_root)
      command = 'AGENT_VM_HOME=' + Shellwords.escape(root) + ' /usr/bin/ruby ' + Shellwords.escape(backend)
      case shell
      when 'bash'
        <<~SH
          # Managed Second Mac completion. Only local metadata is read on Tab.
          _vm_complete() {
            local candidate
            COMPREPLY=()
            while IFS= read -r candidate; do
              COMPREPLY+=("$candidate")
            done < <(#{command} --bash "${COMP_WORDBREAKS-}" "${COMP_WORDS[@]:1:COMP_CWORD}" 2>/dev/null)
            if [ "${#COMPREPLY[@]}" -eq 1 ] && [[ "${COMPREPLY[0]}" == */ ]]; then
              complete -o filenames -o nospace -F _vm_complete vm agent-vm
              type compopt >/dev/null 2>&1 && compopt -o nospace 2>/dev/null
            else
              complete -o filenames -F _vm_complete vm agent-vm
            fi
            return 0
          }
          complete -o filenames -F _vm_complete vm agent-vm
        SH
      when 'zsh'
        <<~SH
          # Managed Second Mac completion. Keep an existing completion setup.
          if (( ! $+functions[compdef] )); then
            autoload -Uz compinit
            compinit -i
          fi
          _vm_complete() {
            local candidate
            local -a candidates directories files
            candidates=("${(@f)$(#{command} "${words[@]:1:$((CURRENT - 1))}" 2>/dev/null)}")
            for candidate in "${candidates[@]}"; do
              [[ -n "$candidate" ]] || continue
              if [[ "$candidate" == */ ]]; then
                directories+=("$candidate")
              else
                files+=("$candidate")
              fi
            done
            (( ${#directories} )) && compadd -S '' -a directories
            (( ${#files} )) && compadd -a files
            return 0
          }
          compdef _vm_complete vm agent-vm
        SH
      else
        raise CommandCatalog::Error, 'Usage: vm completion bash|zsh'
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  bash = ARGV.first == '--bash'
  ARGV.shift if bash
  breaks = ARGV.shift if bash
  puts(bash ? AgentVM::Completion.bash_complete(ARGV, wordbreaks:breaks.to_s) : AgentVM::Completion.complete(ARGV))
end
