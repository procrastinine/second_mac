require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../guest/permissions'

class PermissionsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('second-mac-tcc-')
    @databases = %w[system user].map { |name| File.join(@dir, name + '.db') }
    @databases.each do |db|
      GuestPermissions.run('/usr/bin/sqlite3', db, <<~SQL)
        CREATE TABLE access(service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL,
          auth_value INTEGER NOT NULL, auth_reason INTEGER NOT NULL, auth_version INTEGER NOT NULL, csreq BLOB,
          indirect_object_identifier TEXT NOT NULL DEFAULT 'UNUSED', last_modified INTEGER NOT NULL,
          PRIMARY KEY (service, client, client_type, indirect_object_identifier));
      SQL
    end
  end
  def teardown; FileUtils.remove_entry(@dir); end
  def grants
    GuestPermissions.stub(:writable!, true) do
      GuestPermissions.stub(:prepare, true) do
        GuestPermissions.stub(:databases, @databases) do
          GuestPermissions.stub(:identity, ["test.app';--", 0, 'f00d']) do
            GuestPermissions.stub(:reload, true) { capture_io { yield } }
          end
        end
      end
    end
  end
  def test_parameter_scope_code_identity_and_revoke_use_real_sqlite
    grants { GuestPermissions.grant('/fake/App.app', %w[documents accessibility apple-events:com.apple.finder]) }
    system = GuestPermissions.query(@databases[0], 'SELECT service,client,auth_value,hex(csreq) FROM access;')
    user = GuestPermissions.query(@databases[1], 'SELECT service,client,auth_value,indirect_object_identifier FROM access;')
    assert_equal "kTCCServiceAccessibility|test.app';--|2|F00D\n", system
    assert_includes user, "kTCCServiceSystemPolicyDocumentsFolder|test.app';--|2|UNUSED"
    assert_includes user, "kTCCServiceAppleEvents|test.app';--|2|com.apple.finder"
    grants { GuestPermissions.grant('/fake/App.app', ['documents'], allow:false) }
    assert_equal '0', GuestPermissions.query(@databases[1], "SELECT auth_value FROM access WHERE service='kTCCServiceSystemPolicyDocumentsFolder';").strip
    assert_equal '2', GuestPermissions.query(@databases[1], "SELECT auth_value FROM access WHERE service='kTCCServiceAppleEvents';").strip
  end
  def test_enabled_sip_or_unknown_schema_refuses_changes
    GuestPermissions.stub(:sip_off?, false) { assert_raises(GuestPermissions::Error) { GuestPermissions.writable! } }
    assert_raises(GuestPermissions::Error) { grants { GuestPermissions.grant('/fake/App.app', ['invented']) } }
    db = @databases[0]
    GuestPermissions.query(db, 'DROP TABLE access; CREATE TABLE access (client TEXT);')
    assert_raises(GuestPermissions::Error) { GuestPermissions.columns(db) }
    assert_equal '0', GuestPermissions.query(db, 'SELECT count(*) FROM access;').strip
  end
  def test_system_grants_do_not_require_an_unused_user_database
    File.unlink(@databases[1])
    grants { GuestPermissions.grant('/fake/App.app', ['accessibility']) }
    assert_equal '2', GuestPermissions.query(@databases[0], 'SELECT auth_value FROM access;').strip
    assert_raises(GuestPermissions::Error) { grants { GuestPermissions.grant('/fake/App.app', ['documents']) } }
    refute File.exist?(@databases[1])
  end
  def test_check_distinguishes_missing_denied_and_allowed_without_writing
    check = lambda do |names|
      GuestPermissions.stub(:databases, @databases) do
        GuestPermissions.stub(:identity, ["test.app';--", 0, 'f00d']) do
          GuestPermissions.check('/fake/App.app', names)['permissions']
        end
      end
    end
    assert_nil check.call(['camera'])['camera']
    grants { GuestPermissions.grant('/fake/App.app', %w[camera apple-events:com.apple.finder]) }
    assert_equal({'camera'=>2,'apple-events:com.apple.finder'=>2}, check.call(%w[camera apple-events:com.apple.finder]))
    grants { GuestPermissions.grant('/fake/App.app', ['camera'], allow:false) }
    assert_equal 0, check.call(['camera'])['camera']
    assert_equal '2', GuestPermissions.query(@databases[1], 'SELECT count(*) FROM access;').strip
  end
  def test_user_database_discovery_handles_modern_and_legacy_layouts_without_guessing
    legacy='/Users/developer/Library/Application Support/com.apple.TCC/TCC.db'
    modern='/private/var/containers/Data/ProtectedSystem/00000000-0000-0000-0000-000000000001/Data/Library/Application Support/com.apple.TCC/TCC.db'
    assert_equal legacy, GuestPermissions.user_database("n#{legacy}\nn#{legacy}-wal\n", '/Users/developer')
    assert_equal modern, GuestPermissions.user_database("n/Library/Application Support/com.apple.TCC/TCC.db\nn#{modern}\n", '/Users/developer')
    assert_nil GuestPermissions.user_database("n/Users/builder/Library/Application Support/com.apple.TCC/TCC.db\n", '/Users/developer')
    assert_raises(GuestPermissions::Error) { GuestPermissions.user_database("n#{legacy}\nn#{modern}\n", '/Users/developer') }
  end
  def test_protected_user_records_are_unavailable_without_hiding_system_records
    grants { GuestPermissions.grant('/fake/App.app', ['accessibility']) }
    query = GuestPermissions.method(:query)
    guarded = lambda do |db, statement|
      raise GuestPermissions::Error, 'authorization denied' if db == @databases[1]
      query.call(db, statement)
    end
    GuestPermissions.stub(:databases, @databases) do
      GuestPermissions.stub(:identity, ["test.app';--", 0, 'f00d']) do
        GuestPermissions.stub(:query, guarded) do
          result = GuestPermissions.check('/fake/App.app', %w[camera accessibility])
          assert_equal({'camera'=>'unavailable', 'accessibility'=>2}, result['permissions'])
          assert_equal ['camera'], result['errors'].keys
        end
      end
    end
  end
end
