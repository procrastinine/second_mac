require_relative 'core'

module AgentVM
  module AutoLogin
    # loginwindow's kcpassword format is reversible obfuscation, not encryption.
    # Keep the resulting file root-only, just as macOS does for automatic login.
    KEY = [0x7d, 0x89, 0x52, 0x23, 0xd2, 0xbc, 0xdd, 0xea, 0xa3, 0xb9, 0x1f].freeze

    def self.encode(password)
      raise Error, 'Invalid automatic-login password' if password.empty? || password.include?("\0")
      bytes = password.b.bytes + [0]
      bytes.concat([0] * ((-bytes.length) % KEY.length))
      bytes.each_with_index.map { |byte, index| byte ^ KEY[index % KEY.length] }.pack('C*')
    end

    def self.matches?(encoded, password)
      return false if encoded.empty? || encoded.bytesize % KEY.length != 0
      decoded = encoded.bytes.each_with_index.map { |byte, index| byte ^ KEY[index % KEY.length] }.pack('C*')
      terminator = decoded.index("\0")
      terminator && decoded.byteslice(0, terminator) == password.b
    end
  end
end
