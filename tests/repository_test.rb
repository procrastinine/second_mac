require 'minitest/autorun'
require 'open3'
require 'pathname'

class RepositoryTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def files
    @files ||= if File.directory?(File.join(ROOT, '.git'))
      listing, error, status = Open3.capture3('/usr/bin/git', '-C', ROOT, 'ls-files', '-z', '--cached', '--others', '--exclude-standard')
      raise error unless status.success?
      listing.split("\0").uniq.sort.select { |file| File.exist?(File.join(ROOT, file)) }
    else
      # Source archives have no Git metadata and contain only their public files.
      Dir.glob(File.join(ROOT, '**', '*'), File::FNM_DOTMATCH)
         .reject { |file| File.directory?(file) }
         .map { |file| file.delete_prefix(ROOT + '/') }.sort
    end
  end

  def text_files
    files.to_h { |file| [file, File.read(File.join(ROOT, file), encoding:'UTF-8')] }
  end

  def test_publishable_files_exclude_private_state_and_artifacts
    refute_empty files
    forbidden = %w[.agents .codex .claude .pi .ssh .state .secrets .cache .venv
                   __pycache__ node_modules runtime run output shared-view menu-actions
                   AGENTS.md CLAUDE.md auth.json config.json admin-password known-hosts
                   bootstrap-known-hosts source-manifest.json versions.txt]
    files.each do |file|
      assert_empty file.split('/') & forbidden, "Private artifact in publication: #{file}"
      refute_match(/(?:\.(?:private|local)\.|\.(?:ipsw|asif|img|log|pem|key|p12|pfx|pyc|swp|bak|tmp)\z|(?:^|\/)\.env(?:\.|\z)|(?:^|\/)id_(?:rsa|ed25519))/, file,
                   "Private artifact in publication: #{file}")
      metadata = File.lstat(File.join(ROOT, file))
      assert metadata.file? && !metadata.symlink?, "Only regular source files belong in publication: #{file}"
      assert_operator metadata.size, :<, 256 * 1024, "Unexpected large file: #{file}"
    end
    text_files.each do |file, text|
      assert text.valid_encoding? && !text.include?("\0"), "Non-text artifact: #{file}"
      refute_includes text, "\r", "Use LF line endings: #{file}"
      assert text.empty? || text.end_with?("\n"), "Missing final newline: #{file}"
    end
    %w[agent-vm install.sh bootstrap.sh update.sh tests/run.sh].each do |file|
      assert File.executable?(File.join(ROOT, file)), "Missing executable permission: #{file}"
    end
  end

  def test_source_has_no_credentials_or_personal_home_paths
    patterns = [
      /-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----/,
      /\b(?:sk-(?:or-v1-|ant-api\d+-)?|gh[pousr]_)[A-Za-z0-9_-]{24,}\b/,
      /\bgithub_pat_[A-Za-z0-9_]{24,}\b/,
      %r{https?://[^/\s]+:[^/\s]+@},
    ]
    text_files.each do |file, text|
      patterns.each { |pattern| refute_match pattern, text, "Potential credential in #{file}" }
      text.scan(%r{/(?:Users|home)/([A-Za-z0-9_.-]+)/}).flatten.each do |account|
        assert_includes %w[developer builder GUEST_USER], account, "Use a configurable or example account in #{file}"
      end
      text.scan(/[A-Za-z0-9_.+-]+@[A-Za-z0-9_.-]+\.[A-Za-z]{2,}/).each do |email|
        assert email.end_with?('@example.invalid'), "Use a reserved example address in #{file}"
      end
    end
  end

  def test_relative_documentation_links_resolve
    text_files.select { |file, _| file.end_with?('.md') }.each do |file, text|
      text.scan(/\[[^\]]*\]\(([^)]+)\)/).flatten.each do |link|
        next if link.match?(%r{\A(?:https?://|mailto:)})
        target, anchor = link.split('#', 2)
        destination = target.empty? ? file : Pathname.new(File.join(File.dirname(file), target)).cleanpath.to_s
        exists = files.include?(destination) || files.any? { |candidate| candidate.start_with?(destination + '/') }
        assert exists, "Broken local link in #{file}: #{link}"
        next unless anchor
        content = File.read(File.join(ROOT, destination)).gsub(/^```.*?^```[^\n]*$/m, '')
        headings = content.lines.grep(/^#+ /).map do |line|
          line.sub(/^#+ /, '').strip.downcase.gsub(/[^\p{L}\p{N}_ -]/, '').tr(' ', '-')
        end
        assert_includes headings, anchor, "Broken heading link in #{file}: #{link}"
      end
    end
  end
end
