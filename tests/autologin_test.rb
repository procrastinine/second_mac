require 'minitest/autorun'
require_relative '../lib/autologin'

class AutoLoginTest < Minitest::Test
  def test_loginwindow_format_has_terminator_even_at_block_boundary
    assert_equal '0de82150a5d3af8ea3b91f', AgentVM::AutoLogin.encode('password').unpack1('H*')
    [1, 10, 11, 21, 22, 48].each do |length|
      password = 'x' * length
      encoded = AgentVM::AutoLogin.encode(password)
      assert_equal ((length / 11) + 1) * 11, encoded.bytesize
      assert AgentVM::AutoLogin.matches?(encoded, password)
      refute AgentVM::AutoLogin.matches?(encoded, password + 'x')
    end
  end

  def test_validation_rejects_stale_or_incomplete_credentials
    refute AgentVM::AutoLogin.matches?('', 'test')
    refute AgentVM::AutoLogin.matches?('truncated', 'test')
    refute AgentVM::AutoLogin.matches?(AgentVM::AutoLogin.encode('old-password'), 'new-password')
    password = "caf\u00e9-\u65e5\u672c"
    assert AgentVM::AutoLogin.matches?(AgentVM::AutoLogin.encode(password), password)
    assert_raises(AgentVM::Error) { AgentVM::AutoLogin.encode('') }
    assert_raises(AgentVM::Error) { AgentVM::AutoLogin.encode("in\0valid") }
  end
end
