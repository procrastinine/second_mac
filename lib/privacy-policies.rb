# frozen_string_literal: true
require_relative 'core'

module AgentVM
  module PrivacyPolicies
    POLICIES = {
      'com.apple.SubmitDiagInfo' => {'AutoSubmit'=>false},
      'com.apple.applicationaccess' => {
        'allowDiagnosticSubmission'=>false, 'allowAssistant'=>false,
        'allowApplePersonalizedAdvertising'=>false,
        'allowExternalIntelligenceIntegrations'=>false,
        'allowWritingTools'=>false, 'allowImagePlayground'=>false,
        'allowGenmoji'=>false, 'allowAppleIntelligenceReport'=>false,
      },
      'com.apple.ironwood.support' => {'Assistant Allowed'=>false},
      'com.apple.assistant.support' => {'Assistant Enabled'=>false, 'Siri Data Sharing Opt-In Status'=>2},
      'com.apple.AdLib' => {'allowApplePersonalizedAdvertising'=>false},
      'com.brave.Browser' => {
        'MetricsReportingEnabled'=>false, 'BraveP3AEnabled'=>false,
        'BraveStatsPingEnabled'=>false, 'BraveWebDiscoveryEnabled'=>false,
        'BraveAIChatEnabled'=>false, 'BraveLocalAIEnabled'=>false, 'BraveRewardsDisabled'=>true,
        'BraveWalletDisabled'=>true, 'BackgroundModeEnabled'=>false,
        'PasswordManagerEnabled'=>false,
      },
    }.freeze

    # macOS rebuilds this cache at login. Keep the desired values in installed
    # code outside the cache and repair only missing/changed keys. No recurring
    # writes when healthy, and no removal of unrelated policies in these domains.
    def self.apply(directory = '/Library/Managed Preferences')
      FileUtils.mkdir_p(directory, mode:0755)
      changed = 0
      POLICIES.each do |domain, keys|
        path = File.join(directory, domain + '.plist')
        raise Error, 'Managed policy path must not be a symlink' if File.symlink?(path)
        existing = File.file?(path) ? JSON.parse(AgentVM.run('/usr/bin/plutil', '-convert', 'json', '-o', '-', path, capture:true)) : {}
        desired = existing.merge(keys)
        if existing != desired
          AgentVM.write(path, AgentVM.plist(desired), 0644)
          changed += 1
        end
        stat = File.stat(path)
        File.chmod(0644, path) unless stat.mode & 0777 == 0644
        File.chown(0, 0, path) if Process.uid.zero? && (stat.uid != 0 || stat.gid != 0)
      end
      changed
    end
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV == ['--json']
    puts JSON.generate(AgentVM::PrivacyPolicies::POLICIES)
  else
    abort 'Run as root without arguments.' unless Process.uid.zero? && ARGV.empty?
    changed = AgentVM::PrivacyPolicies.apply
    puts "Restored #{changed} managed privacy policies." unless changed.zero?
  end
end
