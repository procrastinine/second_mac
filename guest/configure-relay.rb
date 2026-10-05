require 'json'
require 'fileutils'
require 'securerandom'

# Only guest-local URLs and a revocable relay token are stored here. Pi owns its
# other settings, routing policy and credentials for other providers.
module ModelRelayClient
  def self.read(path)
    File.file?(path) ? JSON.parse(File.read(path)) : {}
  end
  def self.write(path, value)
    return if File.file?(path) && read(path) == value
    FileUtils.mkdir_p(File.dirname(path), mode:0700)
    temp = path + '.' + SecureRandom.hex(8)
    File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0600) { |f| f.write(JSON.pretty_generate(value) + "\n") }
    File.rename(temp, path)
  ensure
    File.unlink(temp) if temp && File.exist?(temp)
  end
  def self.configure(value, home:Dir.home)
    path = File.join(home, '.config/second-mac/model-relay.json')
    old = read(path)
    pi = File.join(home, '.pi/agent')
    if File.directory?(pi)
      models, auth = read(File.join(pi, 'models.json')), read(File.join(pi, 'auth.json'))
      provider = (models['providers'] ||= {})['openrouter'] ||= {}
      if value['enabled']
        # Save only a previous URL, never a copy of an upstream secret.
        value['previous_base_url'] = old.empty? ? provider['baseUrl'] : old['previous_base_url']
        provider['baseUrl'] = value.fetch('base_url')
        provider.delete('apiKey')
        provider.fetch('headers', {}).delete_if { |key, _| %w[authorization x-api-key].include?(key.downcase) }
        auth['openrouter'] = {'type'=>'api_key', 'key'=>value.fetch('token')}
      elsif !old.empty?
        if provider['baseUrl'] == old['base_url']
          old['previous_base_url'] ? provider['baseUrl'] = old['previous_base_url'] : provider.delete('baseUrl')
        end
        auth.delete('openrouter') if auth.dig('openrouter', 'key') == old['token']
      end
      if value['enabled'] || !old.empty?
        write(File.join(pi, 'models.json'), models)
        write(File.join(pi, 'auth.json'), auth)
        File.chmod(0600, File.join(pi, 'auth.json'))
      end
    end
    if value['enabled']
      write(path, value)
    elsif File.file?(path)
      File.unlink(path)
    end
  end
end
ModelRelayClient.configure(JSON.parse(STDIN.read)) if $PROGRAM_NAME == __FILE__
