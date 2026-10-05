require_relative 'core'
require 'uri'

module AgentVM
  class RestoreImage
    def self.validate(data, local: false)
      raise Error, 'Invalid Apple restore-image metadata.' unless data.is_a?(Hash) &&
        %w[url version build].all? { |key| data[key].is_a?(String) && !data[key].empty? }
      uri = URI.parse(data['url'])
      valid_url = local ? uri.scheme == 'file' && [nil, '', 'localhost'].include?(uri.host) && uri.path.start_with?('/') : uri.scheme == 'https' && uri.host && !uri.userinfo
      raise Error, 'Invalid Apple restore-image URL.' unless valid_url && !data['url'].match?(/[\x00-\x20]/)
      raise Error, 'Invalid Apple restore-image version.' unless data['version'].match?(/\A\d+\.\d+(?:\.\d+)?\z/) &&
        data['build'].match?(/\A[A-Za-z0-9]+\z/)
      data
    rescue URI::InvalidURIError
      raise Error, 'Invalid Apple restore-image URL.'
    end

    def self.latest
      query
    end

    def self.local(path)
      raise Error, 'The selected local restore image does not exist.' unless File.file?(path)
      query(File.expand_path(path))
    end

    def self.query(path = nil)
      source = File.join(__dir__, 'restore-image.swift')
      directory = File.join(AgentVM.state_root, 'helpers', 'restore-image-' + Digest::SHA256.file(source).hexdigest[0,16])
      FileUtils.mkdir_p(directory, mode:0700)
      binary = File.join(directory, 'restore-image')
      File.open(File.join(directory, 'build.lock'), File::RDWR|File::CREAT, 0600) do |lock|
        lock.flock(File::LOCK_EX)
        unless File.executable?(binary)
          incoming = binary + '.new'
          AgentVM.run('/usr/bin/xcrun', 'swiftc', source, '-o', incoming, '-module-cache-path', File.join(directory, 'modules'), capture:true, timeout:300)
          entitlements = File.join(directory, 'entitlements.plist')
          AgentVM.write(entitlements, AgentVM.plist('com.apple.security.virtualization'=>true))
          AgentVM.run('/usr/bin/codesign', '--force', '--sign', '-', '--entitlements', entitlements, incoming, capture:true)
          AgentVM.run('/usr/bin/codesign', '--verify', '--strict', incoming, capture:true)
          File.rename(incoming, binary)
        end
      end
      validate(JSON.parse(AgentVM.run(binary, *[path].compact, capture:true, timeout:180)), local:!path.nil?)
    rescue JSON::ParserError
      raise Error, 'Cannot interpret Apple restore-image metadata.'
    end
  end
end
