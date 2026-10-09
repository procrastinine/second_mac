require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../lib/ui'

class UITest < Minitest::Test
  def setup
    @vm = Object.new
    @vm.define_singleton_method(:config) { {'tart_version'=>'2.40.0'} }
    @ui = AgentVM::Desktop.new(@vm)
  end

  def test_approval_requires_a_recognized_request_and_unique_paired_buttons
    rows = [{'text'=>'A program would like to access your Documents folder', 'x'=>300, 'y'=>200},
            {'text'=>"Don’t Allow", 'x'=>300, 'y'=>300}, {'text'=>'Allow', 'x'=>500, 'y'=>300}]
    clicks = []
    @ui.define_singleton_method(:screen) { {'rows'=>rows} }
    @ui.define_singleton_method(:click) { |row| clicks << row }
    assert @ui.approve_once
    assert_equal ['Allow'], clicks.map { |row| row['text'] }
    rows[0]['text'] = 'Delete these files?'
    refute @ui.approve_once
    rows[0]['text'] = 'A program wants to access your files'
    rows << {'text'=>'Allow', 'x'=>510, 'y'=>300}
    refute @ui.approve_once
    rows.pop
    rows[2]['y'] = 700
    refute @ui.approve_once
    assert_equal 1, clicks.length
  end

  def test_network_filter_dialog_ignores_instruction_pictures_outside_the_active_region
    rows = [{'text'=>'"Firewall" Would Like to Filter', 'x'=>500, 'y'=>228},
            {'text'=>'Network Content', 'x'=>460, 'y'=>247},
            {'text'=>'Allow', 'x'=>453, 'y'=>335}, {'text'=>"Don't Allow", 'x'=>571, 'y'=>334},
            {'text'=>'Allow', 'x'=>645, 'y'=>694}, {'text'=>"Don't Allow", 'x'=>764, 'y'=>694}]
    assert_equal rows[2], AgentVM::Desktop.consent_button('rows'=>rows, 'width'=>1024, 'height'=>768)
    rows[0]['text'] = 'Delete all documents?'
    assert_nil AgentVM::Desktop.consent_button('rows'=>rows)
  end

  def test_unsafe_socket_is_refused_before_connection
    Dir.mktmpdir('sm-ui-') do |dir|
      @vm.define_singleton_method(:tart_directory) { dir }
      @vm.define_singleton_method(:running?) { true }
      server = UNIXServer.new(File.join(dir, 'ui.sock'))
      File.chmod(0666, File.join(dir, 'ui.sock'))
      error = assert_raises(AgentVM::Error) { @ui.request({'op'=>'status'}) }
      assert_includes error.message, 'Unsafe VM UI socket'
    ensure
      server.close if server
    end
  end

  def test_lulu_alert_needs_its_title_connection_text_and_unique_allow_block_pair
    rows = [{'text'=>'LuLu Alert', 'x'=>233, 'y'=>360},
            {'text'=>'is connecting to 203.0.113.1', 'x'=>458, 'y'=>420},
            {'text'=>'Block', 'x'=>585, 'y'=>526}, {'text'=>'AlLoW', 'x'=>756, 'y'=>528}]
    assert_equal rows.last, AgentVM::Desktop.consent_button('rows'=>rows)
    rows[0]['text'] = 'Other dialog'
    assert_nil AgentVM::Desktop.consent_button('rows'=>rows)
    rows[0]['text'] = 'LuLu Alert'
    rows[1]['text'] = 'Delete all files'
    assert_nil AgentVM::Desktop.consent_button('rows'=>rows)
  end

  def test_local_network_consent_wording
    rows = [{'text'=>'Allow "Example" to find', 'x'=>503, 'y'=>229},
            {'text'=>'devices on local networks?', 'x'=>492, 'y'=>248},
            {'text'=>"Don't Allow", 'x'=>454, 'y'=>353}, {'text'=>'Allow', 'x'=>571, 'y'=>355}]
    assert_equal rows.last, AgentVM::Desktop.consent_button('rows'=>rows)
  end

  def test_recovery_rejects_non_keyboard_text_before_sending_any_keys
    sent = []
    recovery = AgentVM::Recovery.new(@vm)
    recovery.define_singleton_method(:key) { |*args, **options| sent << [args, options] }
    assert_raises(AgentVM::Error) { recovery.type("safe\nunsafe") }
    assert_empty sent
    recovery.type('Yz!')
    assert_equal [16,6,18], sent.map { |args, _| args.first }
    assert_equal [1<<17,0,1<<17], sent.map { |_, options| options[:flags] }
  end

  def test_custom_sip_policy_is_not_reported_as_enabled_or_disabled
    @vm.define_singleton_method(:ssh) { |*, **| 'System Integrity Protection status: unknown (Custom Configuration).' }
    assert_raises(AgentVM::Error) { AgentVM::SIP.new(@vm).state }
  end

  def test_source_patch_preserves_guest_transport_version_and_refuses_unknown_upstream
    Dir.mktmpdir('sm-tart-') do |dir|
      FileUtils.mkdir_p(File.join(dir, 'Sources/tart/Commands'))
      FileUtils.mkdir_p(File.join(dir, 'Sources/tart/CI'))
      File.write(File.join(dir, 'Sources/tart/CI/CI.swift'), 'let version = "${VERSION}"')
      File.write(File.join(dir, 'Package.swift'), <<~'SWIFT')
        platforms: [.macOS(.v13)]
          targets: [
        .executableTarget(name: "tart", dependencies: [
            .package(url: "https://github.com/nicklockwood/SwiftFormat", from: "0.99.0"),
            .package(url: "https://github.com/open-telemetry/opentelemetry-swift", exact: "9.0.0"),
              .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
              .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
              .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
              .product(name: "ResourceExtension", package: "opentelemetry-swift"),
      SWIFT
      File.write(File.join(dir, 'Sources/tart/Root.swift'), <<~'SWIFT')
        import OpenTelemetrySdk
        import OpenTelemetryProtocolExporterHttp
        struct Root {
          private static func startCommandSpan(for command: ParsableCommand) -> Span {
            collectPrivateArguments()
          }
        }
      SWIFT
      File.write(File.join(dir, 'Sources/tart/VM.swift'), <<~'SWIFT'.lines.map { |line| '    ' + line }.join)
            let soundDeviceConfiguration = VZVirtioSoundDeviceConfiguration()
            configuration.audioDevices = [soundDeviceConfiguration]
            // Networking
            configuration.directorySharingDevices = directorySharingDevices
      SWIFT
      File.write(File.join(dir, 'Sources/tart/Commands/Run.swift'), "import Virtualization\n        var resume = false\n    if try vmDir.state() == .Suspended {\n              try FileManager.default.removeItem(at: vmDir.stateURL)\n        } catch let error as VZError {\n        try await vm!.run()\n")
      FileUtils.mkdir_p(File.join(dir, 'Sources/SecondMacDisplay'))
      File.write(File.join(dir, 'Sources/SecondMacDisplay/retired.m'), 'obsolete generated source')
      AgentVM::UIBuild.new(@vm).patch(dir)
      refute File.exist?(File.join(dir, 'Sources/SecondMacDisplay/retired.m'))
      assert_includes File.read(File.join(dir,'Sources/tart/CI/CI.swift')), '2.40.0'
      assert_includes File.read(File.join(dir,'Sources/tart/VM.swift')), 'VZUSBScreenCoordinatePointingDeviceConfiguration'
      assert_includes File.read(File.join(dir,'Sources/tart/Commands/Run.swift')), 'SMStartControl'
      package = File.read(File.join(dir,'Package.swift'))
      assert_includes package, 'OpenTelemetryApi'
      refute_match(/OpenTelemetrySdk|Exporter|ResourceExtension|SwiftFormat/, package)
      refute_includes File.read(File.join(dir,'Sources/tart/Root.swift')), 'collectPrivateArguments'
      assert_includes File.read(File.join(dir,'Sources/tart/OTel.swift')), 'DefaultTracer.instance'
      assert File.file?(File.join(dir, 'Sources/SecondMacDisplay/include/SecondMacDisplay.h'))
      assert_raises(AgentVM::Error) { AgentVM::UIBuild.new(@vm).patch(dir) }
      assert_raises(AgentVM::Error) { AgentVM::UIBuild.replace_once('anchor anchor', 'anchor', 'new') }
    end
  end

  def test_build_cache_rejects_a_replaced_binary
    Dir.mktmpdir('sm-build-') do |dir|
      builder = AgentVM::UIBuild.new(@vm)
      builder.define_singleton_method(:directory) { dir }
      File.write(builder.binary, 'original')
      File.chmod(0755, builder.binary)
      File.write(File.join(dir,'manifest.json'), JSON.generate('source_digest'=>builder.digest,
        'binary_sha256'=>Digest::SHA256.file(builder.binary).hexdigest))
      assert builder.ready?
      AgentVM.stub(:run, ->(*) { flunk 'An unchanged patch build must not download or compile' }) do
        assert_equal builder.binary, builder.install
      end
      previous = builder.digest
      builder.define_singleton_method(:digest) { 'updated-patch-inputs' }
      refute builder.ready?
      builder.define_singleton_method(:digest) { previous }
      File.write(builder.binary, 'changed')
      refute builder.ready?
    end
  end

  def test_interrupted_release_clone_can_be_retried_without_manual_cleanup
    @vm.define_singleton_method(:config) { {'tart_version'=>'v2.40.0'} }
    Dir.mktmpdir('tart-checkout-') do |dir|
      builder = AgentVM::UIBuild.new(@vm)
      destination = File.join(dir, 'source')
      builder.define_singleton_method(:source_directory) { destination }
      failed = true
      clone_count = 0
      runner = lambda do |*args, **|
        if args.include?('clone')
          assert_equal 'v2.40.0', args[args.index('--branch') + 1]
          clone_count += 1
          FileUtils.mkdir_p(File.join(args.last, '.git'))
          raise AgentVM::Error, 'Interrupted clone' if failed
          File.write(File.join(args.last, '.git', 'HEAD'), 'completed')
        elsif args.include?('rev-parse')
          assert_equal 'refs/tags/v2.40.0^{commit}', args.last if args.last.start_with?('refs/tags/')
          path = args[args.index('-C') + 1]
          raise AgentVM::Error, 'Incomplete checkout' unless File.file?(File.join(path, '.git', 'HEAD'))
          'a' * 40
        else
          flunk "Unexpected build operation: #{args.inspect}"
        end
      end
      AgentVM.stub(:run, runner) do
        capture_io { assert_raises(AgentVM::Error) { builder.checkout } }
        assert_empty Dir.children(dir)
        # Also repair a partial directory left by the pre-atomic installer.
        FileUtils.mkdir_p(File.join(destination, '.git'))
        failed = false
        capture_io { assert_equal destination, builder.checkout }
        assert_equal destination, builder.checkout
        assert_equal 2, clone_count
      end
    end
  end
end
