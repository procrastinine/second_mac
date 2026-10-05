require 'minitest/autorun'
require_relative '../lib/python-version'

class PythonVersionTest < Minitest::Test
  def entry(version, **changes)
    {'version'=>version, 'implementation'=>'cpython', 'variant'=>'default',
     'url'=>'https://example.test/python.tar.gz'}.merge(changes.transform_keys(&:to_s))
  end
  def test_latest_stable_download_wins_over_installed_old_version_and_prereleases
    catalog = [entry('3.12.9'), entry('3.12.10'), entry('3.13.2'),
               entry('3.14.0rc1'), entry('3.14.0', variant:'freethreaded'),
               entry('3.14.0', implementation:'pypy'), entry('3.15.0', url:nil)]
    assert_equal '3.13.2', AgentVM.python_version(catalog)
    assert_equal '3.12.10', AgentVM.python_version(catalog.first(2))
  end
  def test_requested_exact_version_is_retained_when_catalog_is_filtered
    assert_equal '3.12.9', AgentVM.python_version([entry('3.12.9')])
    assert_raises(RuntimeError) { AgentVM.python_version([]) }
  end
end
