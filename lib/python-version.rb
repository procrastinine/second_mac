require 'json'

module AgentVM
  # `uv python install 3` accepts an older matching installation. Resolve the
  # latest compatible download first, then install that exact catalog version.
  # The selector still controls the range; no version is frozen in this repo.
  def self.python_version(catalog)
    candidates = catalog.select do |entry|
      entry['implementation'] == 'cpython' && entry['variant'] == 'default' &&
        entry['version'].to_s.match?(/\A3\.\d+\.\d+\z/) && entry['url']
    end
    latest = candidates.max_by { |entry| entry['version'].split('.').map(&:to_i) }
    raise 'No stable CPython download matches the configured Python selector.' unless latest
    latest.fetch('version')
  end
end

puts AgentVM.python_version(JSON.parse(STDIN.read)) if $PROGRAM_NAME == __FILE__
