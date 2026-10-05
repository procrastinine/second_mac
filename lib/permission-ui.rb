require_relative 'ui'

module AgentVM
  # English macOS Settings workflows. OCR, fixed UI rules and state readback;
  # no LLM and no host Accessibility or host screen-capture permission.
  class PermissionUI
    PANES = {
      'accessibility'=>['Privacy_Accessibility', 'Accessibility'],
      'full-disk'=>['Privacy_AllFiles', 'Full Disk Access'],
      'input-monitoring'=>['Privacy_ListenEvent', 'Input Monitoring'],
      'screen-recording'=>['Privacy_ScreenCapture', 'Screen & System Audio Recording'],
      'camera'=>['Privacy_Camera', 'Camera'], 'microphone'=>['Privacy_Microphone', 'Microphone']
    }.freeze
    EXTENSIONS = {
      'camera'=>['com.apple.system_extension.cmio.extension-point', 'Camera Extensions'],
      'network'=>['com.apple.system_extension.network_extension.extension-point', 'Network Extensions'],
      'filesystem'=>['com.apple.fskit.fsmodule', 'File System Extensions']
    }.freeze
    def initialize(vm)
      @vm, @ui = vm, Desktop.new(vm)
    end
    def with_lock
      File.open(@vm.file('permission-ui.lock'), File::RDWR|File::CREAT, 0600) do |lock|
        raise Error, 'Another guest permission workflow is active; retry when it finishes.' unless lock.flock(File::LOCK_EX|File::LOCK_NB)
        yield
      end
    end
    def wait(timeout:20)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        page = @ui.screen
        result = yield page
        return result if result
        raise Error, 'Guest Settings did not reach the expected state. Use vm ui inspect; no further input was sent.' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.5
      end
    end
    def rows(page); page.fetch('rows'); end
    def one(page, text)
      matches = rows(page).select { |r| r['text'].casecmp(text).zero? && r['y'] > 70 }
      matches.length == 1 ? matches.first : nil
    end
    def authenticate(page)
      text = rows(page).select { |r| r['x'].between?(350, 650) && r['y'].between?(150, 550) }.map { |r| r['text'] }.join(' ')
      return false unless text.match?(/(?:Privacy & Security|System Extensions) is trying to/) &&
        text.match?(/Password/i) && text.include?('Cancel') && text.match?(/Modify Settings|Unlock|OK/)
      @ui.type(@vm.password)
      @ui.key('return')
      sleep 1
      true
    end
    def switch_state(x, y, strict:true)
      source = File.join(__dir__, 'ui-switch.swift')
      digest = Digest::SHA256.file(source).hexdigest
      binary = @vm.file('ui-switch-' + digest[0,16])
      unless File.executable?(binary)
        AgentVM.run('/usr/bin/xcrun', 'swiftc', '-O', '-module-cache-path', @vm.file('swift-module-cache'), source, '-o', binary, timeout:120)
      end
      png = Base64.strict_decode64(@ui.request({'op'=>'screenshot'}).fetch('png'))
      result = AgentVM.run(binary, x.round.to_s, y.round.to_s, input:png, capture:true, timeout:10).strip
      unless %w[on off].include?(result)
        return nil unless strict
        raise Error, 'Guest switch appearance is unfamiliar; no click was sent. Use vm ui inspect.'
      end
      result
    end
    def set_switch(x, y, enabled)
      desired = enabled ? 'on' : 'off'
      return if switch_state(x, y) == desired
      @ui.click('x'=>x, 'y'=>y)
      authenticated = false
      wait do |page|
        next false if complete_restart(page)
        if !authenticated && authenticate(page)
          authenticated = true
          next false
        end
        switch_state(x, y, strict:false) == desired
      end
    end
    def open_settings(url, heading)
      raise Error, 'Enable guest UI control first: vm ui enable [--restart].' unless @ui.enabled?
      @settings_url = url
      # Close only a recognized extension sheet. Never dismiss arbitrary app dialogs.
      page = dismiss_setup_banners
      return page if one(page, heading) && one(page, 'Done')
      if EXTENSIONS.values.any? { |_, title| one(page, title) } && (done = one(page, 'Done'))
        @ui.click(done)
      end
      @vm.ssh('/usr/bin/open', url, capture:true)
      titles = [heading]
      titles << 'Device Control and Data Access' if heading == 'Accessibility'
      wait { |p| rows(p).any? { |r| r['x'] > 350 && r['y'] < 180 && titles.any? { |title| r['text'] == title || r['text'].start_with?(title[0,25]) } } && p }
      sleep 1 # Settings animates sheets after the first title appears.
      dismiss_setup_banners
    end
    def complete_restart(page)
      reopen = one(page, 'Quit & Reopen')
      return false unless reopen
      @ui.click(reopen)
      sleep 1
      # The restarted app can cover Settings, including with first-run dialogs.
      # Return to the same pane before reading its switches.
      @vm.ssh('/usr/bin/open', @settings_url, capture:true) if @settings_url
      true
    end
    def dismiss_setup_banners
      # These first-login banners cover the right-hand permission switches.
      # Dismiss only these two known macOS notices; unknown overlays fail the
      # subsequent switch check without receiving a speculative click.
      2.times do
        page = @ui.screen
        banner = rows(page).find do |row|
          row['x'].between?(720, 920) && row['y'].between?(50, 230) &&
            (row['text'] == 'Login Item Added' || row['text'].match?(/\ASee what.s new in macOS \d+\z/))
        end
        return page unless banner
        @ui.click('x'=>665, 'y'=>banner['y']-19)
        sleep 0.4
      end
      @ui.screen
    end
    def extension(kind, app)
      with_lock { extension_unlocked(kind, app) }
    end
    def extension_unlocked(kind, app)
      point, heading = EXTENSIONS.fetch(kind) { raise Error, 'Extension kind must be camera, network, or filesystem. Kernel policy stays host-only.' }
      raise Error, 'Choose the exact guest extension app label.' unless app.is_a?(String) && app.bytesize.between?(1,100) && !app.match?(/[\x00-\x1f]/)
      page = open_settings('x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=' + point, heading)
      row, done = one(page, app), one(page, 'Done')
      raise Error, 'The installed extension is not uniquely visible in guest Settings. Launch the app and request its extension first.' unless row && done && row['y'] > 230 && row['y'] < done['y']
      # Network/camera rows have a subtitle and an extra details control;
      # FSKit rows have neither. Read switch state before clicking to make this idempotent.
      x = done['x'] + (kind == 'filesystem' ? 4 : -20)
      y = row['y'] + (kind == 'filesystem' ? 0 : 9)
      set_switch(x, y, true)
      @ui.click_text('Done')
      if kind == 'network'
        sleep 1
        @ui.approve_once
      end
      "Enabled #{heading}: #{app}."
    end
    def grant(app, name, enabled:true)
      with_lock { grant_unlocked(app, name, enabled:enabled) }
    end
    def grant_unlocked(app, name, enabled:true)
      pane, heading = PANES.fetch(name) { raise Error, 'This category needs an app consent dialog or an explicit SIP-off direct grant. Use vm permissions auto on, or vm permissions help.' }
      require_relative 'permissions'
      permissions = Permissions.new(@vm)
      current = JSON.parse(permissions.direct(['check', app, name], capture:true))
      desired = enabled ? 2 : 0
      return "#{name}: already #{enabled ? 'allowed' : 'denied'}." if current.fetch('permissions')[name] == desired
      raise Error, 'Settings grants need an installed .app path.' unless app.end_with?('.app')
      # The filename is only a visual anchor; the selected app and resulting TCC identity are checked separately.
      label = File.basename(app, '.app')
      page = open_settings('x-apple.systempreferences:com.apple.preference.security?' + pane, heading)
      if complete_restart(page)
        page = @ui.screen
      end
      row = one(page, label)
      if row && row['x'] > 390
        set_switch(833, row['y'], enabled)
      else
        raise Error, 'This app must request camera/microphone access first; vm permissions auto on can approve its dialog.' if %w[camera microphone].include?(name)
        raise Error, 'The app has no grant to revoke.' unless enabled
        # macOS 27 places the add control below the first list, 23px under its last row.
        items = rows(page).select { |r| r['x'].between?(400, 650) && r['y'].between?(150, 300) }
        anchor = one(page, 'No Items') || items.last
        raise Error, 'Cannot identify the guest permission list safely.' unless anchor
        @ui.click('x'=>406, 'y'=>anchor['y']+23)
        wait do |p|
          next false if authenticate(p)
          one(p, 'Applications') || one(p, 'Cancel') && (one(p, 'Open') || one(p, 'Add'))
        end
        @ui.keyboard('cmd+shift+g')
        wait { |p| rows(p).any? { |r| r['text'].match?(/Go to(?::| (?:the )?folder)|Enter a path/i) } }
        @ui.keyboard('cmd+a'); @ui.type(app); @ui.key('return')
        sleep 1
        @ui.key('return')
      end
      verified_by = 'permission records'
      wait do |p|
        next false if complete_restart(p)
        authenticate(p)
        state = JSON.parse(permissions.direct(['check', app, name], capture:true)).fetch('permissions')[name]
        if state == 'unavailable'
          visible = one(p, label)
          verified_by = 'Settings (permission records are protected)'
          visible && visible['x'] > 390 && switch_state(833, visible['y'], strict:false) == (enabled ? 'on' : 'off')
        else
          state == desired
        end
      end
      # TCC can commit just before Settings presents its restart notice.
      sleep 1
      complete_restart(@ui.screen)
      "#{name}: #{enabled ? 'allowed' : 'denied'}; verified in #{verified_by}."
    end
  end
end
