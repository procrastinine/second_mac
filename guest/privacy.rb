#!/usr/bin/ruby
require 'fileutils'
require 'open3'
require 'etc'
require_relative '../lib/privacy-policies'

abort 'Run as root, with the guest username as the argument.' unless Process.uid.zero? && ARGV.length == 1
user = ARGV.fetch(0)
account = Etc.getpwnam(user)
abort 'Expected a regular guest account.' if account.uid < 501

def preference(domain, key, value)
  type = value == true || value == false ? '-bool' : '-int'
  text = value == true ? 'true' : value == false ? 'false' : value.to_s
  raise "Unable to set #{domain}:#{key}" unless system('/usr/bin/defaults', 'write', domain, key, type, text)
end

# Mirror opt-outs as ordinary machine preferences as well as managed values.
AgentVM::PrivacyPolicies::POLICIES.each do |domain, keys|
  keys.each { |key, value| preference('/Library/Preferences/' + domain, key, value) }
end
AgentVM::PrivacyPolicies.apply
installed = '/usr/local/libexec/agent-vm'
FileUtils.mkdir_p(installed, mode:0755)
%w[core.rb profile-plan.rb privacy-policies.rb].each do |file|
  FileUtils.install(File.join(__dir__, '..', 'lib', file), File.join(installed, file), mode:0644)
end
label = 'local.agent-vm.privacy'
launch_file = "/Library/LaunchDaemons/#{label}.plist"
system('/bin/launchctl', 'bootout', "system/#{label}", out:File::NULL, err:File::NULL)
AgentVM.write(launch_file, AgentVM.plist({
  'Label'=>label,
  'ProgramArguments'=>['/usr/bin/ruby', File.join(installed, 'privacy-policies.rb')],
  'RunAtLoad'=>true, 'WatchPaths'=>['/Library/Managed Preferences'],
  'StartInterval'=>300, 'ThrottleInterval'=>10,
  'StandardOutPath'=>'/var/log/agent-vm-privacy.log',
  'StandardErrorPath'=>'/var/log/agent-vm-privacy.log'
}), 0644)
AgentVM.run('/bin/launchctl', 'bootstrap', 'system', launch_file)
FileUtils.mkdir_p('/Library/Application Support/CrashReporter', mode:0755)
%w[AutoSubmit AutoSubmitVersion ThirdPartyDataSubmit].each do |key|
  preference('/Library/Application Support/CrashReporter/DiagnosticMessagesHistory', key, key == 'AutoSubmitVersion' ? 4 : false)
end
preference('/Library/Preferences/com.apple.SubmitDiagInfo', 'AutoSubmit', false)
preference('/Library/Preferences/com.apple.SetupAssistant', 'SkipSiriSetup', true)
preference('/Library/Preferences/com.apple.SetupAssistant', 'SkipIntelligence', true)

# File search for agents uses rg/fd. Avoid continuous indexing of tools and caches.
raise 'Could not disable guest Spotlight indexing' unless system('/usr/bin/mdutil', '-i', 'off', '/')
puts 'Guest diagnostic sharing, Siri and browser analytics policies disabled; Spotlight indexing disabled.'
