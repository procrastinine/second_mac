require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/privacy-policies'

class PrivacyTest < Minitest::Test
  def test_policy_repair_preserves_unrelated_keys_and_is_idle_when_healthy
    Dir.mktmpdir('agent-vm-policy-') do |directory|
      path = File.join(directory, 'com.brave.Browser.plist')
      AgentVM.write(path, AgentVM.plist({'UnrelatedSetting'=>'keep', 'BraveP3AEnabled'=>true}), 0644)
      assert_equal AgentVM::PrivacyPolicies::POLICIES.length, AgentVM::PrivacyPolicies.apply(directory)
      read = lambda { JSON.parse(AgentVM.run('/usr/bin/plutil', '-convert', 'json', '-o', '-', path, capture:true)) }
      assert_equal 'keep', read.call['UnrelatedSetting']
      assert_equal false, read.call['BraveP3AEnabled']
      before = Dir.glob(File.join(directory, '*.plist')).to_h { |file| [file, [File.stat(file).ino, File.mtime(file)]] }
      assert_equal 0, AgentVM::PrivacyPolicies.apply(directory)
      assert_equal before, before.keys.to_h { |file| [file, [File.stat(file).ino, File.mtime(file)]] }
      File.unlink(path)
      assert_equal 1, AgentVM::PrivacyPolicies.apply(directory)
      assert_equal false, read.call['MetricsReportingEnabled']
      assert_equal 0644, File.stat(path).mode & 0777
    end
  end

  def test_policy_repair_refuses_symlinks_and_invalid_existing_data
    Dir.mktmpdir('agent-vm-policy-') do |directory|
      path = File.join(directory, 'com.apple.SubmitDiagInfo.plist')
      original = File.join(directory, 'unrelated.txt')
      File.write(original, 'keep')
      File.symlink(original, path)
      assert_raises(AgentVM::Error) { AgentVM::PrivacyPolicies.apply(directory) }
      assert_equal 'keep', File.read(original)
      File.unlink(path)
      File.write(path, 'not a plist')
      assert_raises(AgentVM::Error) { AgentVM::PrivacyPolicies.apply(directory) }
      assert_equal 'not a plist', File.read(path)
    end
  end
end
