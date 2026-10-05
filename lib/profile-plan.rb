require 'json'
require 'fileutils'

module AgentVM
  # Shared by the host CLI and the guest installer. No host paths enter a plan.
  module ProfilePlan
    LEGACY = %w[base web science documents media build].freeze
    DESCRIPTIONS = {
      'base'=>'Shell, tmux, Git, Node, uv Python and command-line essentials',
      'web'=>'Brave, Playwright, Ketch, HTML parsing and web APIs',
      'science'=>'NumPy, SciPy, plotting, Torch/Metal, notebooks and ML libraries',
      'documents'=>'PDF, Office, OCR, typesetting and document conversion',
      'media'=>'FFmpeg, yt-dlp, ImageMagick, metadata and image utilities',
      'build'=>'Python/JS/TS/shell checkers, test tools, Go, Rust, Java and native builds',
      'latex'=>'Full TeX Live command-line tools, latexmk and Biber (large optional download)'
    }.freeze

    def self.expand(names, agents = [])
      raise ArgumentError, 'Profiles must be an array.' unless names.is_a?(Array)
      unknown = names - DESCRIPTIONS.keys - ['full']
      raise ArgumentError, "Unknown profiles: #{unknown.join(', ')}" unless unknown.empty?
      selected = names.include?('full') ? DESCRIPTIONS.keys : ['base'] + names
      # Every supplied agent module includes browser/search integration.
      selected += ['web'] unless agents.empty?
      DESCRIPTIONS.keys.select { |name| selected.include?(name) }
    end

    def self.generate(config, packages, destination, requested = nil)
      selected = expand(requested || config.fetch('profiles', LEGACY), config.fetch('agents', []))
      FileUtils.mkdir_p(destination)
      %w[Brewfile python.txt npm.txt].each do |file|
        lines = selected.flat_map do |profile|
          path = File.join(packages, 'profiles', profile, file)
          File.file?(path) ? File.readlines(path).map(&:strip).reject { |line| line.empty? || line.start_with?('#') } : []
        end
        File.write(File.join(destination, file), lines.uniq.join("\n") + "\n")
      end
      File.write(File.join(destination, 'profiles'), selected.join("\n") + "\n")
      selected
    end
  end
end

if $PROGRAM_NAME == __FILE__
  config_path, packages, destination, *requested = ARGV
  abort 'Usage: profile-plan.rb CONFIG PACKAGES OUTPUT [PROFILE...]' unless destination
  AgentVM::ProfilePlan.generate(JSON.parse(File.read(config_path)), packages, destination, requested.empty? ? nil : requested)
end
