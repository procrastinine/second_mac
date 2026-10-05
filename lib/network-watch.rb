require_relative 'network'
begin
  name, owner = ARGV
  raise AgentVM::Error, 'Expected VM name and owner PID.' unless ARGV.length == 2 && owner.match?(/\A[1-9]\d*\z/)
  AgentVM::Network.new(AgentVM::VM.load(name)).watch(Integer(owner))
rescue AgentVM::Error => error
  warn error.message
  exit 1
end
