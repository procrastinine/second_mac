# Tests and diagnostics

The repository tests protect installation, configuration, storage and sharing
behavior. They run on the host with temporary fixtures and do not boot a VM,
install guest packages or require model credentials.

## Run the suite

On macOS with Command Line Tools and Homebrew:

```sh
brew install uv node go
./tests/run.sh
```

The suite uses macOS's `/usr/bin/ruby`, uv's isolated Python environment, Node
for JavaScript syntax checks, and the Apple compiler for Swift syntax/type
checking. Go tests exercise packet filtering and bootstrap restrictions with
the latest network library in a temporary module. The first run downloads
those dependencies; the first uv run may download Python and `xattr`.
macFUSE does not need to be installed or mounted. GitHub Actions runs the same
suite on a macOS runner.

With a logged-in graphical macOS session, an additional window lifecycle check
is available:

```sh
bash tests/display-check.sh
```

It opens its own synthetic window to exercise Hide/Unhide, Minimize/Restore and
capture cleanup with the production display code. It uses no VM, private input
interfaces, host Accessibility permission or other applications' windows, and
does not save screenshots. It is separate from unattended CI because it needs
a WindowServer session. Real guest rendering/input checks remain separate.

To check a new Tart release without changing or downloading a macOS VM:

```sh
ruby tests/tart-ui-check.rb latest           # Apply patches to latest stable source
ruby tests/tart-ui-check.rb 2.40.1 --build   # Compile and locally sign this release
```

The default check validates patch anchors against real upstream release source;
CI runs it alongside the suite. `--build` also compiles, verifies the signature,
and reuses the same content-addressed cache as the installer. Neither command
activates a build in an existing VM. Successful compilation does not replace
live desktop/input testing on a supported host macOS version.

Coverage includes:

- Host credential relay authentication, transparent request forwarding,
  streaming before completion, provider error/redirect handling without retries,
  cancellation, key rotation, and idempotent Pi setup/revocation. These use a
  local fake provider and synthetic keys, with no paid inference.

- Installer option handling, shell PATH setup, retries, bootstrap cloning, safe
  Git updates, combined Second Mac/VM-tool updates, deferred guest updates while
  stopped, and separate guest macOS maintenance. Updates retain guest developer packages.
- Interrupted dependency/guest setup, credential retention, per-stage retries,
  reuse of an already installed OS, guest setup locks, and host-only completion
  retries. These use failure fixtures rather than another Apple restore.
- Concurrent UI compilation/image preparation, process cleanup on cancellation,
  reuse of completed results, current-build cache selection and saved restore
  metadata. Guest-only OS update scope is checked separately from host maintenance.
- Network configuration, quoting, password handling, GUI/menu behavior, and
  source/runtime integrity.
- Agent additions install only the named modules; failures restore the previous
  selection and clean staging. Invalid port arguments cannot start a guest.
  Background forwards release captured command output while remaining active.
- Concurrent installers serialize shared release caches and keep independent
  download temporaries; a busy release can be retried without cache corruption.
- VPN helper updates select current dependencies explicitly, reuse unchanged
  builds on startup, preserve retained copies, and recover from failed builds
  without replacing the last working version. Native-only updates skip them.
- Concurrent settings updates preserve unrelated changes and reject conflicting
  writes; sharing rollback preserves revoked network grants. Invalid lifecycle
  options and help requests cannot power off a guest. Catalog checks restore
  stopped/suspended state without applying pending configuration.
- Interrupted runtime-source cloning recovers without manual cache deletion;
  compiler cleanup preserves current caches, referenced binaries and guest disks.
  Successful VM-tools updates clean obsolete compiler caches; other scopes and
  failed updates retain them. A busy compiler defers cleanup without failing an
  otherwise completed update.
- Direct network descriptor handoff, live helper replacement, failure recovery,
  owner-only control and helper cleanup without a Tart patch; desktop show/hide
  without restarting a VM that has its optional UI controller attached.
- Throwaway menu states and confirmation boundaries, permission SQL/code
  identity, refusal of unsupported SIP/TCC states, unsafe UI sockets,
  conservative consent matching, and upstream UI build/version/cache checks.
- Guest-control loopback binding, authentication/revocation, operation scopes,
  input limits, serialization, private client credentials, optional autostart,
  one-boot grants, stop-time revocation and stale generations.
- Content-based guest update receipts, deferred releases collapsing into one
  application, no-op updates, failed-update retries, restored disks, optional
  camera helper refresh, preserving VM running/stopped state, and excluding
  retained throwaways from updates and startup migrations.
- Scoped filesystem exports, guest symlink provenance, path confinement,
  atomic saves, ordinary file operations and failed-mount cleanup.
- Disk locking/growth, independent copies, snapshot checksums, restore rollback,
  recovery and image-cache selection.
- Throwaway disk independence, disabled host grants, stable IDs, retention after
  script failure, saved-runtime command routing, explicit deletion, backup
  exclusions and refusal of full-copy fallback.
- Privacy-policy restoration, preservation of unrelated settings, and refusal
  to follow symlinks or overwrite malformed preference files.
- The publishable file set: no VM state, credentials, local agent notes, binary
  artifacts, personal home paths or broken local documentation links.

These tests remain in the source checkout. They are not installed in the guest.

## Diagnose an installed VM

```sh
vm doctor
```

This checks the installed runtime against its source manifest, connects over
SSH, and checks guest transport/sharing/privacy services, the shared filesystem,
DNS configuration and effective privacy settings. It starts the VM if needed.
It does not benchmark developer packages, launch browsers, generate sample
files, or make web-search/model requests. A changed source checkout needs
`vm update` to synchronize its host runtime and VM tools. `./update.sh` does the
same. Use `--second-mac-only` to retain dependency versions, or `--configuration`
to apply pending guest configuration immediately while preserving its power state.

For sharing changes, the optional `tests/guest-sharing.sh` exercises executable
files, Git, uv environments and npm dependencies in a writable test share:

```sh
vm ssh /bin/bash -s -- shared_files < tests/guest-sharing.sh
```

Replace `shared_files` with the configured guest folder name. It creates and
removes a temporary project there and downloads its own dependencies. Use it
only when reviewing filesystem changes, separately from normal VM maintenance.

## Verification limits

End-to-end verification has covered an Apple Silicon macOS 27 host and guest,
including local-image reuse, configurable accounts/shares, optional modules,
isolated networking, port forwarding, Finder access, GUI controls and storage
operations. Replication used local APFS copies to avoid another macOS download
and installation. A clean-host Command Line Tools/Homebrew installation
and a second full Apple restore have not been replayed.
CI checks local behavior; it does not provide nested virtualization or a claim
that every current upstream release works on every Mac.

With a full-tunnel host VPN active, native Softnet failed both DNS and direct-IP
HTTPS checks, including after a guest restart and with Softnet 0.24.0. The
host-socket backend passed HTTPS checks and matched the host's verified VPN
egress. These tests establish that behavior for the tested VPN setup; they are
not a forced VPN-failure/leak test across all VPN applications and policies.

Automatic ASIF reclamation was checked on a local replica: a 1 GiB guest write
increased the image's allocation by about 1 GiB, and deleting it returned that
allocation to baseline within five seconds while the VM remained running.
That measures the image's allocation, not blocks still retained by independent
host snapshots or clones.

An actual macOS 27.0 to 27.0.1 upgrade completed through the managed OS updater
(now selected separately with `vm update --macos`).
Post-upgrade checks covered retained credentials and package versions, SIP,
automatic login, VPN egress, all three shares, Finder access, desktop show/hide
and OCR. Repeating `vm update --macos` correctly detected the up-to-date guest.

Guest-only display/input checks covered show/hide while retaining the same SSH
process, owner-only local sockets, rejected host operations, real Documents
consent with SIP enabled, and direct Accessibility grant/revoke behavior.
SIP changes were verified after normal boots of a disposable local copy.
Guest-control checks used that same local-copy approach: guest-originated UI
inspection/clicks/consent approval, loopback-only listeners, rejected tokens and
host/SIP operations, off/re-enable revocation, fresh credentials after a
managed restart, and automatic cleanup after guest-initiated shutdown.
The main guest's delegation remains off unless explicitly
enabled by its owner.
These checks do not make OCR a universal permission recognizer or guarantee
that private input APIs remain compatible with future macOS releases.

Lifecycle checks also covered live UI enable/disable, playback mute/unmute,
an output-only sound device with no input channels, and guest macOS reboot
without replacing Tart. A custom process started strictly headless also created
its viewer live, keeping automation disabled until explicitly enabled and
preserving the same Tart and SSH processes. Network off/on retained the same SSH process and both
explicit forwarding directions while external egress was blocked. Temporary
native and scoped-link fixtures verified live attachment changes, read-only
enforcement, busy-file refusal and continued writeback.

Hidden-display checks used an offline APFS clone on Apple Silicon with macOS
27.0.1 and Tart 2.40.1. A continuously animated guest desktop used about
2.5–2.7% of one CPU core in the previous parked Tart viewer. The disconnected
viewer used about 0.1%; a strict headless launch and a show/hide cycle stayed
in that same range. These are 25-second Tart-process CPU samples, not total
VM/GPU measurements or a guarantee for every workload. The guest virtual GPU
remains enabled. Fresh OCR frames, 50 consecutive captures across visibility
changes, rapid screenshot/OCR sequences, keyboard
and pointer input, and repeated show/hide kept the same Tart and SSH processes.
Cold GUI starts were checked with automation both enabled and disabled, and
offline Recovery capture used the same display implementation without changing
SIP. Captures wait for their stream to stop before the hidden view disconnects.
Initial OCR can still take tens of seconds; that was observed in both builds.
The native AppKit Hide/Unhide path was subsequently checked through five
capture cycles on an offline guest copy with the same Tart and SSH processes.
The synthetic display check also covers Minimize/Restore and captures while
minimized. Captures leave the user's original window state intact.

Real save/restore checks kept the same guest boot UUID and tmux server process
while replacing Tart. Regular Tart was tested with two native shares; custom
Tart with all three shares and output audio, including post-resume linked
writeback. Device ordering is stable across launches. Failure checks reject
partial/unmanaged state and changed hardware; a failed restore is never treated
as authorization to boot fresh. These checks do not certify saved memory across
host OS upgrades or every possible third-party virtual device.

Release workflow replication also ran the public `--from-vm` installer on a
local APFS copy with different folder names, then enabled the linked folder live.
Catalog-only macOS checks returned both stopped and suspended copies to their
original power states. The suspended copy retained its guest boot and tmux;
package inventories and credential hashes stayed unchanged. An ordinary-Tart
retained copy separately verified the installed CLI, SwiftBar suspended state,
private access defaults and memory resume without updating its saved runtime.
The copies and temporary shared fixtures were removed after verification.

On macOS 27 with SIP enabled, guest tests covered Settings grants for
Accessibility, Full Disk Access, Input Monitoring and screen recording, native
camera/microphone consent, LuLu's network extension/content filter, and an actual
macFUSE FSKit mount with read/write/fsync. The kernel backend reached Apple's
Recovery policy requirement; it is not supported in current macOS VMs according
to macFUSE. This does not affect the host kernel backend used for linked shares.
LuLu checks included an actual denied public connection followed by a successful
connection from an automatically approved app. Local Network consent was tested
separately from Softnet's host/LAN restrictions; granting consent does not remove
those restrictions.

Camera transport was checked with generated video, through Tart into the guest
OBS extension and back out through an actual camera client. Pixel content was
verified, along with LaunchServices/FIFO capture and automatic termination when
the generation is revoked or its owner lock is released. No host camera,
microphone or desktop capture was used for these tests. Actual host media
consent and physical microphone input require an explicit per-machine opt-in.

Installer/start migration checks also used a new local APFS replica of the
existing guest. Its first managed start installed the current guest CLI helpers,
applied virtual-display power settings, retained SIP and kept host media,
sharing and delegation disabled. Repeating the helper migration was idempotent.
The same implementations are used by fresh installation and existing-VM
configuration updates; no developer-tool demonstrations run during installation.
Guest command migration uses `mac-control`, removes only recognized retired
Second Mac scripts, preserves unrelated commands and symlinks, and avoids
rewriting unchanged helpers. Host `vm` remains a separate command.

`vm check-sleep` requires a physical lid-close/open cycle. A simulated transport
pause is not proof of real sleep/wake behavior. This physical test remains a
per-machine check; a reboot, VM crash or terminal exit can end SSH regardless.

Filesystem correctness tests are not a native-APFS performance benchmark.
Cross-boundary advisory locks are not a verified coordination mechanism; see
[SHARING.md](SHARING.md) for the supported sharing semantics.
