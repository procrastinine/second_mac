---
name: mac-control
description: Test and operate GUI workflows inside a Second Mac guest using mac-control screenshots, OCR, mouse actions, text entry, shortcuts, and automated guest app permissions.
---

# mac-control

Run these commands **inside the guest**. `mac-control` controls that guest's
desktop; the separate host `vm` command manages the VM. No model service,
guest Accessibility grant, or host screen/input permission is needed for the
controller itself.

## Observe and act

Start with `mac-control status` and `mac-control capabilities`. The latter
reports the running viewer's controls. If a pointer update is pending, basic
click/key/type/screenshot/OCR still work; a host-side update and later VM
restart activate the extra gestures. Do not restart a working guest without
the user's authorization.

```sh
mac-control screenshot /tmp/before.png
mac-control inspect
mac-control click-text 'Settings'
mac-control click 320 240
mac-control click 320 240 --count 2
mac-control click 320 240 --button right
mac-control move 320 240
mac-control drag 180 220 640 480 --duration 0.8
mac-control scroll down 400 --at 700 500
mac-control key cmd+comma
mac-control key cmd+a
mac-control type 'replacement text'
mac-control key return
mac-control key right --hold-ms 500
mac-control screenshot /tmp/after.png
```

Open the PNG with your image-viewing tool. Screenshot pixels, OCR centers and
pointer coordinates share a **1024×768 top-left origin**, regardless of Retina
scaling or host window size. Target coordinates from a fresh observation.
`click-text` requires one exact, case-insensitive OCR match; use coordinates
when labels repeat, OCR misses an icon, or dragging is needed. `scroll` names
the direction to reveal content, defaults to 320 pixels at the display center,
and supports `--at X Y` for a specific pane. Verify the resulting screen after
actions, especially before repeating a submit, drag, or paste whose outcome is
uncertain. A successful input response confirms delivery, not application state.

## Text and shortcuts

`type` sends US-layout key events and accepts ASCII, tabs and newlines, up to
4096 bytes. Newlines send Return and tabs move focus; use a separate `key return`
when submission should be deliberate. Focus the intended field first. Prefer
stdin for secrets, generated text, or awkward quoting:

```sh
printf %s 'literal text' | mac-control type
printf '%s' 'Unicode: café 日本語' | mac-control paste
```

`paste` explicitly replaces **the guest's** clipboard with UTF-8 plain text and
sends Cmd-V. It leaves that guest clipboard set; it never reads or changes the
host clipboard. It also works around keyboard-layout differences. A field may
refuse paste (some secure fields do); use `type` for supported characters or
report that limitation. Never echo secrets or put them in screenshots/reports.
`mac-control password --local` copies the account password to the guest clipboard;
then focus its password field and run `mac-control key cmd+v`. Avoid plain
`mac-control password` over SSH: its default clipboard target is the SSH terminal.

`key` supports cmd/command, shift, ctrl/control and alt/option combinations,
letters, punctuation (including `comma` and `plus`), arrows, Return, Tab, Escape,
Backspace/Delete, forward-delete, Home/End, PageUp/PageDown and F1–F12.
An updated viewer holds each key for 80 ms before releasing it, including keys
sent by `type`. For games or other apps that poll held state, use
`mac-control key right --hold-ms 500` to request a deliberate hold (10–5000 ms).
Modifiers stay down for the press and are released afterward. Holds finish in
the controller even if the caller disconnects. `capabilities` reports
`timed_keys` and `key_hold_ms`; an older viewer rejects explicit durations and
reports `key_timing_update_pending`. Its legacy taps can still be missed by
polling apps. Do not treat a successful command as proof the app saw the input;
verify its behavior. Long ASCII typing is paced; prefer `paste` for large text
when changing the guest clipboard is acceptable.
`mac-control help COMMAND` gives syntax. Screenshot file writes return JSON with
the path and dimensions; `mac-control screenshot -` emits PNG on redirected stdout.

## App permissions and easy mode

For an app under test, reuse the built-in permission workflow:

```sh
mac-control check /Applications/Example.app accessibility
mac-control grant /Applications/Example.app accessibility
mac-control approve
```

`approve` handles one recognized visible consent dialog. Supported `grant`
operations automate guest Settings with SIP on. Camera and microphone grants
need the app's initial request. If the host has enabled automatic approval
(`vm permissions auto on`), recognized guest dialogs are handled automatically;
preserve that choice. Host `vm guest-control on` enables the guest's control
access when needed. Do not change SIP, host permissions, clipboard sharing,
or the user's automatic-approval policy to complete an ordinary GUI test.

If access is unavailable, report the specific error and needed host setting.
`mac-control doctor` and `mac-control help` work without GUI-control access.
