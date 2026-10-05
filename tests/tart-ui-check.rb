#!/usr/bin/ruby
require_relative '../lib/ui-build'

# Explicit maintainer check; no VM is created, started or changed.
begin
  args = ARGV.dup
  compile = args.delete('--build')
  raise AgentVM::Error, 'Usage: ruby tests/tart-ui-check.rb [release|latest] [--build]' if args.length > 1
  release = args.first || 'latest'
  if release == 'latest'
    metadata = AgentVM.run('/usr/bin/curl', '--fail', '--silent', '--show-error', '--location',
      '--proto', '=https', '--proto-redir', '=https', '--max-time', '30',
      'https://api.github.com/repos/openai/tart/releases/latest', capture:true, timeout:40)
    release = JSON.parse(metadata).fetch('tag_name')
  end
  vm = AgentVM::VM.new(AgentVM::DEFAULTS.merge('tart_version'=>release))
  builder = AgentVM::UIBuild.new(vm)
  version = builder.version
  if compile
    builder.install
    puts "Tart #{version}: UI compilation and local signature verified."
  else
    Dir.mktmpdir('second-mac-tart-check-') do |directory|
      source = File.join(directory, 'source')
      AgentVM.run('/usr/bin/git', '-c', 'advice.detachedHead=false', 'clone', '--quiet',
        '--depth', '1', '--branch', builder.release_tag, 'https://github.com/openai/tart.git', source, timeout:600)
      head = AgentVM.run('/usr/bin/git', '-C', source, 'rev-parse', 'HEAD', capture:true).strip
      tag = AgentVM.run('/usr/bin/git', '-C', source, 'rev-parse', "refs/tags/#{builder.release_tag}^{commit}", capture:true).strip
      raise AgentVM::Error, 'Checkout does not match the requested release.' unless head == tag
      builder.patch(source)
      puts "Tart #{version}: patches apply to release #{tag}. Use --build to compile them."
    end
  end
rescue AgentVM::Error, JSON::ParserError, KeyError => error
  warn error.message
  exit 1
end
