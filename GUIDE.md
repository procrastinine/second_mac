# Using Second Mac

[Project overview](README.md) · [Installation](INSTALL.md) · [Feature guide](FEATURES.md) · [Sharing](SHARING.md) · [Restart matrix](CAPABILITIES.md)

Jump to [commands](#everyday-commands), [retained copies](#retained-throwaways),
[SSH and tmux](#ssh-sleep-and-tmux), [desktop](#occasional-desktop-access),
[permissions](#guest-only-ui-and-permissions), [audio and camera](#optional-audio-camera-and-microphone),
[passwords](#guest-password-and-clipboard), [files and networking](#files-and-network-isolation),
[tools](#tools-and-metal), [agents](#optional-agents-and-credentials),
[updates and privacy](#privacy-updates-and-backups), [backups](#checkpoints-and-backups),
or [SwiftBar](#swiftbar).

## Everyday commands

Run `vm help` for the command overview. `vm help snapshot` and
`vm snapshot --help` explain a command; `vm help snapshot restore` and
`vm snapshot restore --help` explain a nested action. Help works before a VM is
installed and never starts or changes one.

The installer enables Tab completion for the host's Bash or zsh. Tab suggests
commands, options, fixed choices, local snapshot names and retained-copy IDs.
It reads only local metadata; it never starts a VM, opens SSH or queries guest
files or tmux. To enable it in an already-open terminal:

```sh
eval "$(vm completion zsh)"   # zsh
# or: eval "$(vm completion bash)"
```

For commands forwarded into the guest, flags after the guest program stay with
that program: `vm ssh python --help` shows Python's help. `vm ssh --help` shows
Second Mac's SSH help. Use `vm codex -- --help` for an agent's own help.

See the [capability and restart table](CAPABILITIES.md) for regular versus
custom Tart, live operations, and changes that take effect at the next start.

| Command | Result |
| --- | --- |
| `vm status` | VM state, allocated resources, share and state locations |
| `vm access` / `vm access --json` | Configured versus attached host folders, port forwards, media and guest-control access |
| `vm resources` / `vm resources --json` | CPU/RAM settings, disk capacity, and actual host disk allocation |
| `vm start` | Start without a visible desktop; restore sharing and configured port forwards |
| `vm stop` | Unmount files safely and shut down; release VM CPU/RAM |
| `vm restart` | Clean shutdown and start; ends guest processes and SSH sessions |
| `vm reboot` | Reboot guest macOS; retain Tart when the framework allows it |
| `vm suspend` / `vm resume` | Save/recover guest memory, processes and tmux while releasing host CPU/RAM; reconnect SSH |
| `vm runtime` / `vm runtime standard\|custom\|auto` | Inspect actual capabilities / choose the runtime for the next cold start |
| `vm ssh` | Open a shell; start the VM if necessary |
| `vm gui` | Start with a native desktop window, or show its existing window |
| `vm gui --restart` / `vm gui --headless` | Explicitly restart if a window cannot be attached live / hide the window without ending work |
| `vm gui --hide` | Hide the native window while the VM and SSH keep running |
| `vm ui enable [--restart]` | Build and enable optional host-side control of the guest's virtual display/input |
| `vm ui inspect` / `vm ui approve` | Read visible guest text / approve one recognized guest consent dialog |
| `vm permissions auto on` / `off` | Opt into / stop automatic guest consent approval while the VM runs |
| `vm permissions grant /Applications/App.app accessibility` | Change a supported guest permission through Settings, keeping SIP on |
| `vm camera on` / `off` | Opt into / stop video from the host's OBS Virtual Camera |
| `vm audio on` / `off` | Configure output-only playback for the next start; `--restart` explicitly applies it now |
| `vm audio mute` / `unmute` | Change guest playback immediately without restarting |
| `vm microphone on [--restart]` / `off [--restart]` | Opt into / remove host default microphone input separately |
| `vm sip status` / `on` / `off` | Inspect / change guest SIP through paired Recovery; changes reboot the guest |
| `vm password` | Copy the guest administrator password to the host clipboard |
| `vm password --guest` / `vm password --show` | Copy into the guest clipboard / display in an interactive terminal |
| `vm ssh command arguments` | Run a guest command; its arguments are kept as words |
| `vm ssh 'cd src && make \| tail'` | Run one shell line (a single argument is a line, as with `ssh`) |
| `vm sudo command arguments` / `vm sudo 'shell line'` | Run as root with the stored administrator password, which never appears on a command line; stdin and the exit status pass through |
| `vm cp ./dir :~/` / `vm cp :~/out.log .` | Copy into / out of the guest with scp; guest paths start with `:` and directories copy recursively |
| `vm tmux` / `vm tmux session` | Create a tmux session / attach to one |
| `vm mount` / `vm unmount` | Mount guest `/` in host Finder / unmount it |
| `vm shares` | Show all host-to-guest folders and their access modes |
| `vm shares configure --sharing hybrid --linked-files` | Apply the three-folder layout with host macFUSE; live on current custom Tart, otherwise stop first |
| `vm network off` / `on` | Disconnect/reconnect external networking while keeping SSH and explicit port forwards |
| `vm agents add pi codex claude` | Install/update only the named agents; preserve other agents |
| `vm profiles` / `vm profiles add science documents` | List tool profiles / add missing tool groups |
| `vm profiles install PROFILE...` | Fill missing packages from the current manifests, including already selected profiles |
| `vm images` | List reusable local images without starting a guest |
| `vm cache` / `vm cache clean` | Inspect / remove obsolete Tart compiler intermediates; keep current build caches, finished runtimes and all guest storage |
| `vm throwaway [SCRIPT [ARG...]]` | Make a retained copy of the stopped VM; optionally run a local script and shut the copy down |
| `vm throwaway list [--json]` | List retained copies, their IDs, status and disk locations |
| `vm throwaway ssh ID` / `gui ID` / `mount ID` | Reopen a copy by SSH, desktop, or Finder |
| `vm throwaway ssh ID CMD` / `sudo ID CMD` / `cp ID SRC... DEST` | Run, run as root, or copy files in a copy, as `vm ssh`, `vm sudo` and `vm cp` |
| `vm throwaway stop ID` / `delete ID` | Shut down a copy / explicitly delete a stopped copy |
| `vm snapshot create NAME` / `vm snapshot restore NAME` | Create/restore a stopped-VM checkpoint |
| `vm backup DIRECTORY` / `vm restore DIRECTORY` | Save a private backup / restore it to this managed VM |
| `vm apply` | Reapply the current repository's configuration and verify it |
| `vm update` / `./update.sh` | Update Second Mac, Tart, Softnet, SwiftBar and managed guest helpers together; keep guest macOS and defer guest changes while stopped |
| `vm update --check` | Check Second Mac and VM tool updates without contacting the guest |
| `vm update --configuration` | Also apply pending guest configuration now; briefly start a stopped VM only if needed; leave saved memory suspended |
| `vm update --macos` | Update guest macOS using installed host tools; reapply managed settings after the OS update |
| `vm update --macos --check` | Check guest macOS updates; restore the previous power state after scanning |
| `vm update --second-mac-only` | Update Second Mac code/configuration without upgrading Tart or other dependencies |
| `vm doctor` | Check runtime integrity, SSH, guest services, sharing, DNS and privacy settings |
| `vm logs` | Inspect the host's VM startup log |
| `vm check-sleep` | Test the same SSH process across a real lid-close/open cycle |

Use `vm force-stop` only for a stuck guest; it is an abrupt power-off. Ordinary shutdown refuses to force-unmount busy files.

The sparse ASIF disk's configured capacity is a ceiling, not a 100 GB allocation at creation. Shutdown releases active CPU/RAM but preserves the guest disk. Deleting the VM with Tart deletes its guest data. Keep backups of guest-only work before deleting it; sharing does not automatically back up the entire guest.

`vm access` is a read-only overview, including while stopped. It separates saved
settings from this boot's attachments, checks guest mounts and service status,
and reports unavailable evidence as **unknown**. It does not start the VM, open
media devices, test internet destinations, or grant access. Port status means
the forwarding controller is alive, not that the application behind it is
healthy. The network policy is the configured policy, not a firewall audit.
`vm throwaway access ID [--json]` also inspects old retained copies without
updating their saved runtime. An older running copy without an attachment
receipt reports those attachments as unknown. Host paths in this host-only
report are not sent to the guest.

Change resources while stopped:

```sh
vm stop
vm resources --cpus 4 --memory 8 --disk 150
vm start
```

Flags can be used individually. Memory is in GiB; disk capacity is in decimal GB. CPU/RAM changes apply at the next start. Disk capacity can grow; macOS relocates Recovery and expands the main APFS filesystem, and the command verifies both. It rejects shrinking and refuses to interrupt a running VM. Resource reporting does not start a stopped VM.

**Deleted guest data can be reclaimed automatically** through APFS discard/TRIM and ASIF without shrinking the virtual capacity. Reclamation is not necessarily immediate: open deleted files, guest snapshots, and host APFS clones/snapshots can retain blocks. `vm resources` reports allocated image blocks; this is not an estimate of exclusive storage when clones share blocks. No zero-filling, snapshot deletion, or unsupported `hdiutil compact` operation is needed. Package caches remain actual guest data until you intentionally clean them.

Guest cache maintenance is managed inside the guest, independently of Second
Mac updates. For example, `vm ssh uv cache prune` removes unreachable
uv cache entries and also removes centralized project environments if that uv
feature is in use; those environments are rebuilt as needed. It retains ordinary
project-local `.venv` directories. `vm ssh brew cleanup` removes stale Homebrew
downloads and old formula versions. These run only when requested; installation
does not delete your project files or prune snapshots. Use the package managers'
cleanup commands rather than deleting their cache directories directly. See
[uv cache maintenance](https://docs.astral.sh/uv/concepts/cache/#clearing-the-cache)
and [Homebrew cleanup](https://docs.brew.sh/Manpage#cleanup-options-formulacask-).

Automatic ASIF reclamation is already the normal path; an extra scheduled
compaction job is unnecessary. The useful cleanup choices are:

| Storage | Recommended policy |
| --- | --- |
| Deleted guest files | Let guest APFS discard freed blocks and ASIF reclaim them automatically; no restart or free-space filling |
| Old host compiler intermediates | Successful VM-tools updates run `vm cache clean` automatically, retaining current caches for fast rebuilds and any referenced runtime |
| Guest package caches | Managed inside the guest using its package managers; Second Mac updates do not run guest cleanup or install a cleanup schedule |
| Retained throwaways and VM checkpoints | Host-stored VM disk copies; delete explicitly when no longer wanted. They can retain older file contents even after those files are deleted from the main VM |
| Host Time Machine local snapshots | Let macOS purge them as needed; do not automatically remove unrelated host backup history |

Host compiler cleanup runs as part of the update, without a background job. A
throwaway or checkpoint retaining an older file is still using its bytes; no
compaction can reclaim those bytes while preserving that copy's contents.

## Retained throwaways

Throwaways are excluded from Second Mac updates. Each keeps the management-code
snapshot and guest software/configuration it was created with; starting it does
not run later configuration migrations. `vm update`, `./update.sh` and `vm apply`
target the main VM and refuse retained throwaways. Update the main VM and create
a new copy when you want the newer setup. Existing copies stay writable: you can
install tools and change files inside them independently. Their applications and
macOS still follow their own update settings. Host drivers and macOS remain shared
host dependencies.

`vm throwaway` creates an independent copy of the **current stopped VM**, stored
on the host as another runnable VM. It
includes that guest's tools, files, browser state and credentials. It has no
host shared folder or inherited port forwards. It is useful for temporary
logins and experiments whose local changes should stay out of Second Mac;
it is not a clean environment for code that must not see existing guest secrets.

```sh
vm stop
vm throwaway --name experiment ./task.sh argument
vm throwaway list
vm throwaway ssh ID
vm throwaway cp ID ./project :~/
vm throwaway ssh ID 'cd project && ./test.sh'
vm throwaway sudo ID installer -pkg /tmp/x.pkg -target /
vm throwaway gui ID
vm throwaway mount ID
vm throwaway stop ID
vm throwaway delete ID
```

Replace `ID` with the eight-character ID printed at creation or by `list`.
Omit the script to create a stopped copy for later use. `--name` is optional;
the default name contains the ID. A selected local script is copied into the
guest, without sharing its parent directory. Scripts with a shebang use that
interpreter; other scripts use Bash. Script arguments and its exit status are
preserved. After a script finishes, the copy shuts down and **keeps its disk**,
including on failure. Nothing is automatically deleted. Interrupted setup is
listed as incomplete for inspection or explicit deletion.

`ssh`, `gui` and `mount` start a stopped copy as needed. `status`, `resources`,
`password` and `ports` also accept a throwaway ID. These use the same implementation
as `vm --name VM_NAME COMMAND`; explicitly added port grants apply only to that
copy. Deletion refuses a running or suspended VM. The main VM is never stopped,
restarted or modified by the copy command.

SwiftBar lists retained copies with their IDs and states, and provides creation,
start/shutdown/restart, suspend/resume when supported, shell/tmux, desktop, Finder mounts, port forwarding and
explicit deletion. Creating from a running main VM offers a separate, confirmed
shutdown-and-copy action. The menu icon shows running when any managed copy is
running. Main and throwaway VMs can run concurrently, subject to available
resources and Apple's virtualization limits; copying still requires a stopped
source. Polling the menu never boots a VM.

Cloning requires the source and destination on the same APFS volume. It shares
unchanged blocks and refuses a full-copy fallback: no second macOS download or
restore is performed. Writes in either guest are independent. New copies inherit
the main VM's current macOS version; retained older copies can keep old OS blocks
and consume space as they diverge. `resources` reports allocated image blocks,
not exclusive physical usage. Delete unwanted copies explicitly to release
blocks no longer referenced elsewhere.

When Time Machine has a configured destination, each throwaway's entire VM
directory and private management state are excluded. Normal shared host files
keep their existing backup policy. Actions against online accounts, cloud sync
and other remote services are outside the disk boundary and are not undone by
deleting a copy.

## SSH, sleep, and tmux

SSH travels through Tart's VirtIO RPC channel to the guest's loopback SSH server. It does not depend on a guest IP lease or your Wi-Fi staying connected. SSH heartbeat and idle-disconnect timers are disabled so a host sleep can pause the transport without deliberately expiring the session. The host's normal lid-close sleep behavior is retained; guest work pauses while the host sleeps.

This design targets **the same SSH connection surviving sleep**, not an automatic reconnect. A host reboot, VM shutdown/crash, killed terminal, or transport failure can still end a connection. Run `vm check-sleep` on your own Mac to verify an actual lid cycle; a simulated pause is not a substitute for that check.

Tmux is available without being forced on every shell. It includes mouse scrolling, a mouse-mode toggle, guarded Option-click cursor movement, large scrollback, activity indicators, convenient pane splits, extended keys, focus events, and intentional-copy clipboard support. `Prefix + r` reloads configuration. Guest applications do not get general clipboard forwarding to the host.

## Occasional desktop access

`vm gui` retains the same network, sharing, audio, clipboard and USB isolation.
It enables no VNC or Screen Sharing server. With regular Tart, ordinary
`vm start` keeps the native window hidden and ready; `vm gui` shows it without
restarting or breaking SSH. This retains a graphical Tart application and may
briefly display its window while launching. It is not a new viewer attached to a
strictly headless Tart process. `--no-desktop-on-demand` selects strict headless
startup. `vm gui --headless` hides an existing window without restarting.
A regular Tart process already started with `--no-graphics` needs
`vm gui --restart` once, or a later normal start. Current custom Tart can create
its viewer live, including after a strict headless start. Only an explicit
cold restart ends guest sessions.
`vm restart` retains a visible desktop, otherwise starts without a visible window.

The custom build starts without a host rendering view. Closing, hiding or
minimizing its desktop disconnects the view from the VM, including when using
`vm gui --hide` or macOS Hide. While hidden,
it does not keep an offscreen viewer rendering. Screenshots and OCR briefly
attach a private view and disconnect it after the request. Showing the desktop
attaches it live without restarting Tart or macOS. This also applies when UI
automation is disabled. Disconnected view/window objects are reused for capture;
hiding does not promise to release every graphics or OCR cache.
A visible viewer, captures and automatic permission polling consume resources
while in use. The guest retains its virtual GPU, WindowServer and graphical
apps, including Metal/MPS support; hiding the viewer does not stop guest work.
Regular Tart's hidden window is not the same as this detached view.

GUI startup waits for the configured account's desktop login. macOS's native
automatic login uses the generated guest password, without simulated keystrokes.
The installer configures loginwindow and its root-only `/etc/kcpassword` file,
which also works when provisioning over SSH without an existing desktop session.
This standard automatic-login file contains a recoverable password, not encryption.
Once started with a GUI, `vm gui` shows the window and `vm gui --hide` hides it
without restarting. **Closing the stock Tart window stops the VM**; use Hide to leave
work running. A manually locked/logged-out desktop still requires authentication;
automatic login applies to startup. Window activation uses normal macOS app APIs,
without Accessibility or Automation control.

## Guest-only UI and permissions

For occasional desktop use, the ordinary `vm gui` needs no additional build.
For scripted clicks, typing or consent approval, enable the optional controller:

```sh
vm ui enable                 # live on current custom Tart; builds/starts if stopped
vm ui enable --restart       # explicit cold restart when upgrading a stock/old process
vm ui inspect                # guest text and coordinates, using local OCR
vm ui click-text 'Allow'      # requires exactly one visible matching label
vm ui key cmd+shift+p
printf %s 'text to type' | vm ui type
vm ui screenshot > guest.png
vm ui approve                # one recognized permission dialog
vm permissions auto on       # watch while this VM is running
vm permissions auto off
vm ui disable                # revoke automation live on current custom Tart
vm runtime standard          # use ordinary Tart at the next cold start
```

The first enable downloads and compiles the installed Tart release with a small
display extension, using the host Command Line Tools. No macOS image or guest
tools are reinstalled. The signed build is cached in private host state; future
source/Tart changes rebuild it on the next start. The build uses local ad-hoc
signing, with no Apple Developer account. It keeps Tart's local version marker
because the guest transport uses it to check VM compatibility; that marker is
not a telemetry request or a host identifier.

Builds use an upstream release tag matching the installed Tart and verify its
commit before patching; they never track Tart's development `HEAD`. New installs
and `vm update` select the latest stable release. Two people using
the same Second Mac revision and Tart release get the same patch sources, but
installs made at different times may select different Tart releases. Each build
records the exact upstream commit, patch digest and executable checksum locally.

The optional build removes OpenTelemetry exporters, resource collection and
command-argument tracing, and skips the unused SwiftFormat build dependency.
The small no-op tracing API remains to keep upstream integration changes small;
setting tracing environment variables cannot enable an exporter in this build.
The guest transport, image operations and upstream license notices are retained.

The controller runs in the host's VM process. It captures only its own virtual
display window and sends input directly to virtual keyboard/pointer devices.
It installs no guest UI helper, requests no guest Accessibility/screen grants,
and uses no host desktop capture, Accessibility automation or host input events.
Its owner-only Unix socket is unavailable from the guest or LAN. There is no
VNC server. With this controller enabled, `vm gui` and `vm gui --hide` show/hide
the display without restarting; closing its window hides it too. SwiftBar offers
Show desktop / Hide desktop for both the main VM and retained copies. Shells,
tmux sessions and background work continue while the desktop is hidden.

For sharing this project, publish the Second Mac repository as it is: it contains
the display sources and build recipe, with no Tart submodule or bundled VM.
Each user can opt into `vm ui enable`; the script fetches the release matching
their installed Tart, applies the integration and builds it locally. Neither
the publisher nor the user needs an Apple Developer account for this path.
The build is reused until its inputs change. Upstream source changes can require
an updated integration; the build checks its expected source locations and
stops with an error if they no longer match. It does not merge changes silently.
Tart and modified Tart builds retain [Tart's own license](https://github.com/openai/tart/blob/main/LICENSE),
including its redistribution notice and commercial-use restrictions. Shipping a
downloadable prebuilt app with Developer ID signing/notarization would be a
separate distribution option; this installer does not require it.
macOS may ask a newly built executable to access selected shared volumes. That
approval is separate from Accessibility or control of the host desktop.

Text recognition uses Apple's local Vision `VNRecognizeTextRequest` in accurate
mode. It needs no LLM, API key, internet connection or Apple Intelligence model
download. Permission workflows use English labels and fixed rules. The guest's
virtual display stays awake for unattended use; host sleep settings are unchanged.
The guest desktop must be logged in and unlocked.

Automatic approval is off by default. When enabled, a host process follows this
VM's lifetime, approving recognized English consent dialogs with paired
Allow/Don't Allow buttons, plus LuLu's recognized connection alerts. This is
OCR-based convenience, not a universal or
security-grade permission recognizer. It cannot approve every System Settings,
administrator, FileVault or kernel-extension prompt. Explicit Settings workflows
handle supported app grants and their guest administrator prompts. Input assumes a
US keyboard and printable ASCII. The input implementation uses private
Virtualization.framework interfaces, tested on macOS 27; future macOS changes
may require an update. No host-control fallback is used if they fail.

Supported Settings grants work with SIP enabled:

```sh
vm permissions grant /Applications/OBS.app screen-recording accessibility
vm permissions grant /Applications/OBS.app input-monitoring full-disk
vm permissions check /Applications/OBS.app screen-recording camera
vm permissions revoke /Applications/OBS.app accessibility
vm permissions extension camera OBS
vm permissions extension network LuLu
vm permissions extension filesystem macFUSE
vm permissions extension filesystem 'macFUSE (local)'
```

Camera and microphone must first be requested by the guest app, then their
existing Settings switches can be changed. `check` reports stored permission
records: `2` allowed, `0` denied, `null` no record, or `unavailable` when macOS
protects the store. A record alone does not prove an app successfully used a
device. Settings workflows also read back the switch when records are protected.
macOS 27 labels Accessibility as **Device Control and Data Access**.

Extension commands enable an already installed extension by its exact visible
app label; they do not download LuLu or macFUSE into the guest. FSKit works in the
guest without lowering boot security. The macFUSE kernel backend is a different
case: [macFUSE documents third-party kext loading as unsupported in current macOS
VMs](https://github.com/macfuse/macfuse/wiki/Getting-Started). Disabling SIP is not
a kext-enablement workaround. Normal linked-folder sharing needs macFUSE only
on the host, where the kernel backend remains supported.

Direct grants for an installed guest app are an explicit alternative:

```sh
vm sip off                   # guest Recovery reboot; host SIP is unchanged
vm permissions grant /Applications/Example.app documents downloads
vm permissions revoke /Applications/Example.app documents
vm sip on                    # restore guest SIP through Recovery
```

`vm permissions status` lists supported permission names. Direct grants require
guest SIP off and a signed app/executable identity. They run through the existing
authenticated guest transport, save a private TCC database backup inside the
guest, and may require restarting the affected app. With SIP off, automatic
approval also grants recorded TCC requests. `vm permissions auto on --disable-sip`
explicitly selects both behaviors and reboots if necessary. Turning auto off or
SIP back on does not revoke existing grants. The installer leaves SIP enabled.
On macOS 27 the tool locates the configured user's active TCC database in its
protected system container; older guest layouts use the home-directory store.
SIP-off macOS can bypass protected-folder denials even when a deny record exists.
Use ordinary UI approval with SIP on when that broader reduction is unnecessary.

To let software inside the VM request these actions itself, enable the separate
guest-control mode **from the host**:

```sh
vm guest-control on          # enable now and automatically on later starts
vm guest-control autostart on # enable on later starts; leave the current run unchanged
vm guest-control autostart off # disable future starts; leave the current run unchanged
vm guest-control on --once   # enable for the current VM run; preserve autostart
vm guest-control off --once  # disable for the current VM run; preserve autostart
vm guest-control status
vm guest-control off         # revoke now, remove its forward, and disable autostart
```

Enable guest UI once with `vm ui enable` (or `--restart` if an already-running VM
needs to attach the controller). New installations selecting `--ui` enable
guest-control autostart too; use `--no-guest-control-autostart` to keep control
host-only. `--guest-control-autostart` also selects UI support on a new install.
Existing settings and throwaways retain their saved choices. Stopping the VM
revokes its token and stops the service/forward, even with autostart enabled.
Guest-initiated shutdown also ends the service; autostart grants a fresh token
on the next managed start. Its internal tunnel also reconnects after a guest
macOS reboot without restarting Tart. Updating Second Mac preserves this choice.

Inside an enabled, running guest:

```sh
mac-control approve          # approve one recognized consent dialog
mac-control inspect          # text/coordinates from this Mac's display
mac-control click-text Allow
mac-control key cmd+shift+p
printf %s 'text' | mac-control type
mac-control screenshot > screen.png
mac-control grant /Applications/OBS.app screen-recording
mac-control revoke /Applications/OBS.app accessibility
mac-control doctor           # managed services, sharing, DNS and privacy checks
mac-control help
```

Without selecting UI support, this mode is off. The host command is **`vm`**; the guest command is
**`mac-control`**. The installer provides the guest helper, and managed starts
refresh it and remove recognized older Second Mac commands named `vm` or
`vm-control`. No old-name alias is kept, and unrelated user-installed commands
are preserved. The helper needs no UI permissions. Capture and input still run on
the host. A token-authenticated, host-loopback service reaches only that VM
through a dedicated guest-loopback reverse forward. It has no host command,
SIP, reboot, sharing, host-media or network-rule operations. Supported Settings
grants and ordinary dialog approval work with SIP on; direct database grants
still require SIP already disabled by the host.
The mode covers the guest account, not an individual agent or app.

The endpoint and forward stop when the VM stops or the mode is disabled. The
setting persists across managed starts, with a fresh token each time. Enabling
it while stopped takes effect at the next `vm start`; enabling it while running
does not interrupt SSH. Throwaways always start with this mode disabled, even
if their source enabled it. An inherited client/token cannot authorize the
source VM's next run. Use `vm throwaway guest-control ID on --once` to opt in for
one run of a particular copy, or `vm throwaway guest-control ID autostart on`
to enable its later starts independently. Automatic permission approval is also
cleared when creating a throwaway. Disabling the mode preserves existing grants; an action
already issued may finish. `type` accepts up to 512 bytes of printable US-keyboard
text per call. Second Mac updates refresh an enabled main-VM service and its
client; a stopped main VM receives the latest client on its next managed start.
Retained throwaways use their own saved runtime and client.

SIP changes use the VM's paired Recovery disk with its original virtual identity
and verify the result after a normal boot. Disabling SIP is offline. Re-enabling
it restores Full Security, which can require Apple's online signing service;
that Recovery boot uses the selected network backend with the usual host/LAN
blocks and no shares or port forwards. [Apple explains the boot-security signing policy](https://support.apple.com/guide/security/sec7d92dc49f/web).
Recovery
navigation is deterministic English OCR and can stop if Apple's screens change.
The same commands work on copies, for example `vm throwaway sip ID status` and
`vm throwaway ui ID enable`.

## Optional audio, camera and microphone

Output and input are separate, both off by default:

```sh
vm audio on                 # output-only on the next start; microphone stays off
vm audio on --restart       # explicitly restart a running VM to attach output
vm audio mute               # immediate guest volume change; sessions continue
vm audio unmute
vm audio status
```

Output plays through the host's default speakers/headphones even headlessly.
`--audio-output` selects it during installation. It uses the same cached custom
Tart build as optional UI control, without enabling that controller. An
output-only device has no host microphone source or guest input stream. `mute`
is a guest volume setting that guest software can change; `off` removes host
playback at the next start. Turning audio on/off never restarts a running VM
unless `--restart` is explicit.

Both are off by default, and throwaways always start with both off. Only a host
command can opt in; guest-control has no media-enablement operation.

```sh
vm ui enable                 # needed for automatic guest camera setup
vm camera setup              # install guest receiver only; forwarding stays off
vm camera on                 # install missing OBS/FFmpeg and enable video
vm camera status
vm camera off                # revoke video without restarting the VM
vm microphone on --restart   # explicitly ends current guest sessions
vm microphone off --restart
```

In **host OBS**, choose your scene and click **Start Virtual Camera**. First use
may require enabling OBS's camera extension and approving **Second Mac OBS
Bridge** in host Privacy & Security > Camera. Those host decisions stay manual.
If setup reports that OBS's virtual device is unavailable, finish that host step
and rerun `vm camera on`. Inside the guest, select **OBS Virtual Camera** in the
consuming app. Inside the guest, use `mac-control camera status`.

The source matches OBS's specific device identity. It never falls back to the
physical webcam or captures the host screen directly. OBS determines which
camera, screen or scene is included. The guest's signed OBS camera extension is
installed and enabled automatically; guest OBS does not need to keep running.
Video uses 1280×720 at up to 30 fps, hardware H.264 encoding and Tart's private
guest channel, with no listening video port. It is compressed video, not a
lossless device passthrough. Stopping the VM or bridge also stops capture.

Video includes no audio. Microphone sharing separately uses the host-default
input device and leaves playback unchanged. It changes virtual
hardware, so its setting queues for the next cold start. `--restart` explicitly
applies it immediately and ends guest sessions. Playback can be muted live with
`vm audio mute`. Any host microphone consent stays user-controlled.

These commands are optional additions to the same installed `vm` tool. A plain
`vm update` updates their host implementation; the next managed start refreshes
the guest CLI helpers. Rerun `vm camera setup` to refresh its optional guest
receiver after an update. Developer and agent packages remain independently
managed inside the guest.

## Guest password and clipboard

`vm password` copies the guest administrator password to your Mac's clipboard;
`--copy` is an alias and `--show` displays it only in an interactive terminal.
Inside the guest, use **`mac-control password`**. Over SSH it requests a host
terminal clipboard write using OSC 52 (or tmux's clipboard command); in a guest
desktop terminal it uses the guest clipboard. `mac-control password --local`
always selects that Mac's desktop clipboard; the host equivalent is
`vm password --guest`. An SSH terminal must support
and allow clipboard writes; the helper never queries your host clipboard.
iTerm2 calls this setting “Applications in terminal may access clipboard.”
If the terminal blocks it, run `vm password` on the host instead.

`mac-control password`, `mac-control camera status` and `mac-control doctor` work locally even when
guest-control delegation is disabled. UI and permission operations require
the host to enable `vm guest-control on` (or the installer's `--ui` default).

The guest's shell and helper output use ordinary Mac terminology, with no
agent instruction files or setup notes in its documents. This is not VM
concealment: macOS exposes its virtual hardware model, and necessary transport,
sharing and management components remain discoverable.

The guest account can read its own generated administrator password from a
private file under `/etc/agent-vm`, so its agents can also use it for guest
administration. It is never stored in the share or public repository. Passwords
are passed to maintenance commands through stdin and are not logged. Automatic
host/guest clipboard sharing remains disabled; these copy commands are explicit.

## Files and network isolation

The VM uses NAT: a virtual router translates its outbound traffic onto the host's network connection. Bridged networking would instead place the VM directly on the physical LAN as another computer. NAT alone does not block access to the host or LAN; both backends enforce the policy below. Bridging is not enabled by this setup, and SSH does not need it.

Both network backends block the host, private ranges, connected IPv4 LAN subnets, link-local addresses and multicast. Connected subnet detection also covers LANs using public addresses. The host watcher checks those restrictions every three seconds even when the backend stays the same; `vm network refresh` requests an immediate refresh. [Softnet rejects guest IPv6 frames on the host](https://github.com/openai/softnet/blob/0.23.0/lib/proxy/vm.rs#L17-L52); the VPN-compatible backend does too, and IPv6 is also disabled in the guest. Audio is opt-in; clipboard sharing and USB accessories are disabled. Showing the graphical display is opt-in through `vm gui`. There is no host SSH-agent or X11 forwarding.

### Host VPNs and live network changes

`auto` is the default. Without a tunnel on the host's public IPv4 route, the VM
uses ordinary Softnet/vmnet and Quad9 DNS. No additional packet proxy runs in
that path. When that route uses a VPN, the VM uses an isolated
[gvisor-tap-vsock](https://github.com/containers/gvisor-tap-vsock) router that
opens ordinary host TCP/UDP sockets. DNS uses the host's resolver through the
private virtual router, accommodating VPN DNS policies without opening access
to other host services. The router exposes no guest-accessible management API.

```sh
vm network status
vm network auto                # Detect and follow the host's VPN route
vm network vpn                 # Explicit host-socket backend, including split VPNs
vm network native              # Explicit native Softnet backend
vm network refresh             # Refresh restrictions and renew DHCP/DNS live
vm network off                 # Disconnect Ethernet; keep SSH and explicit forwards
vm network on                  # Restore the previous automatic/native/VPN selection
vm throwaway network ID status
vm throwaway network ID auto
```

The host watcher follows route changes while the VM runs and exits when its
own VM process stops. SwiftBar provides the same controls for the main VM and
each throwaway. Changing a stopped VM's selection does not start it. Copies
retain their own settings and host runtime; updating the main VM does not
update existing throwaways.

Backend changes replace the network helper and renew guest DHCP/DNS.
A connected-subnet-only update refreshes the helper's restrictions without
renewing guest addressing or DNS.
macOS stays running; VirtIO SSH sessions, shared folders, Finder transport, and
explicit port forwards retain their connections. Existing **internet** TCP
connections can break when the router or VPN changes. An older running Tart
process needs one restart to activate the supervisor; subsequent network
changes do not. Networking works with official, unmodified Tart. A small host
supervisor holds Tart's Ethernet socket and passes it directly to the chosen
helper; it never reads or relays packets. Its control socket is private to the
host account and unavailable from the guest. This is independent of the optional
UI controller and needs no Tart rebuild. Go is installed automatically on first
use of the VPN backend; its dependencies use the latest available release at
build time. Build caches are reused and excluded from Time Machine.

Tart 2.40.1's `--net-host` uses Apple's native host-only network. It allows host
connectivity without internet routing, so it does not replace these isolated
internet backends.

Automatic detection examines the route to `1.1.1.1`; it cannot infer every
split-tunnel or application-specific VPN policy. Choose `vpn` explicitly for
those configurations. The installer does not change VPN/firewall rules or
exclude processes from a tunnel. Verify the exit address with your VPN provider
if coverage matters. The host VPN controls its routing and kill-switch policy;
Second Mac does not override its traffic blocks. If you intentionally disconnect
the VPN and the host permits ordinary internet access, automatic mode can use
that access. `vpn` selects host sockets, not a separate VPN connection or an
independent requirement that a VPN stay connected.

The compatibility backend adds userspace TCP/IP work;
normal native networking and local file/SSH transports do not acquire that
overhead. Internet ICMP/ping is not forwarded by the compatibility backend.

`vm doctor` checks configuration and local services, not internet connectivity.
To distinguish DNS failure from broader connectivity failure:

```sh
vm ssh /usr/bin/dig example.com +time=3 +tries=1
vm ssh /usr/bin/curl -q --noproxy '*' --connect-timeout 5 --max-time 8 --head https://1.1.1.1/
```

If direct HTTPS also times out, changing DNS alone cannot fix it. Some host
VPN firewalls reject vmnet traffic even when ordinary host sockets work;
`vm network vpn` selects the compatible backend without weakening host/LAN
isolation.

A host application firewall such as LuLu cannot identify individual guest processes. [LuLu filters host socket flows and uses host process identities](https://github.com/objective-see/LuLu/blob/v4.4.3/LuLu/Extension/FilterDataProvider.m#L1193-L1197), while [Softnet forwards VM packets through vmnet](https://github.com/openai/softnet). In VPN mode, host socket flows belong to the network helper. Do not assume a host LuLu rule for Tart filters native VM internet traffic. Both backends enforce the network boundary independently; per-application rules inside the VM require a guest firewall. This installer does not change host LuLu rules or install a guest firewall.

Explicit TCP forwarding uses authenticated SSH and binds only to loopback on each side:

```sh
# A host llama.cpp service at 127.0.0.1:8080 becomes guest localhost:8080.
vm ports host 8080

# A guest web app at localhost:3000 becomes host localhost:3000.
vm ports guest 3000

# Optional second port changes where it appears on the receiving side.
vm ports guest 3000 43000
vm ports list
vm ports remove host 8080
```

Only configured ports are forwarded. Mappings persist across `vm stop`/`vm start`; their listeners stop with the VM. These commands support TCP, not arbitrary UDP forwarding.

`vm mount` opens the guest's **root filesystem** at `~/VMs/VM_NAME` using authenticated, encrypted native SMB over Tart's private channel, without an SSH tunnel. It presents the guest's `/Applications`, `/Users`, and other directories, subject to the guest account's permissions. It does not expose the host's home directory to the VM. The host can also use ordinary `sftp VM_NAME` or `scp file VM_NAME:destination` through the installed SSH alias.

Host-to-guest sharing is described in [SHARING.md](SHARING.md). Only the chosen host directory and explicitly exported targets should contain data you intend the guest to read or modify. Full-access agents can modify shared host files, even though the surrounding host remains isolated. File contents you choose to share may themselves contain identifying information; path filtering cannot redact document contents.

## Tools and Metal

The unpinned lists in [packages/profiles](packages/profiles/) are the authoritative inventory:

| Profile | Tools |
| --- | --- |
| `base` (always included) | uv Python, Ruff, Node/npm, Git/GitHub CLI, tmux, shell completions, rg/fd/jq, editor, 7-Zip (`7zz`), xz/zstd/pigz and CLI essentials |
| `web` | Brave/Playwright, Ketch, HTTP/HTML parsing, web frameworks and model API clients |
| `science` | NumPy, SciPy, Matplotlib, pandas/Polars, Torch/Metal, notebooks and ML libraries |
| `documents` | PDF/Office/image libraries, pandoc, Ghostscript/Poppler/qpdf, OCR, LibreOffice, Graphviz, Tectonic and Typst |
| `media` | ffmpeg/ffprobe, yt-dlp, ImageMagick, Pillow, ExifTool, MediaInfo, WebP and SVG tools |
| `build` | Python/JS/TS/shell checkers and testing tools, Go, Rust, Java, native build tools, pnpm/Bun, just and hyperfine |
| `latex` | Full TeX Live without GUI apps: pdflatex, xelatex, lualatex, latexmk, Biber and packages/fonts; a large optional download |
| `full` | Every profile above; coding agents remain optional |

Select profiles at installation with `--profiles web,science` or add them later with `vm profiles add documents media latex`. Selecting a supplied agent also selects `web` for its browser/search support. Adding a profile installs missing packages; it does not invoke a bulk package upgrade or replace an existing managed Python. `vm profiles install media` explicitly fills newly listed or missing packages in an already selected profile. The large LaTeX profile is optional and included in `full`. macOS already supplies zip/unzip, tar, gzip and bzip2.

The `documents` profile's Tectonic is a smaller LaTeX workflow (`tectonic file.tex`); its first compilation fetches needed TeX resources. Choose `latex` for conventional TeX commands and a broad local package/font collection, including offline compilation. It installs the current Homebrew `mactex-no-gui` cask with the existing private guest administrator credential; no host password is copied into the VM. `full` includes this large profile. The completed TeX installer download is cleaned up automatically. New shells include `/Library/TeX/texbin` automatically. TeX updates remain guest-managed, for example with `tlmgr` or Homebrew; `vm update` does not update them.

The managed `biber` launcher handles the bundled universal executable's incompatibility with newer Apple `lipo` tools. It caches an ARM64 slice of the installed binary, preserves the TeX distribution, and automatically regenerates the cache when that binary changes. Native binaries and script launchers run directly. This keeps Biber matched to the distribution's BibLaTeX package.

The ready-to-use Python is `~/tools/python/bin/python`, first on the guest shell's path. Project environments should use `uv venv` or `uv sync`. Existing project virtual environments take precedence when activated. Later Python upgrades are your own uv workflow; the VM configuration updater does not replace environments.

### Code checks and project environments

The `build` profile supplies commands for ad hoc work and existing configurations:

| Work | Available tools |
| --- | --- |
| Python | Ruff (also in `base`), mypy, Pyright, Black, isort, Flake8, Pylint, Bandit, pre-commit; pytest with asyncio, coverage and parallel-worker plugins, plus Hypothesis |
| JS/TS | TypeScript, ESLint, Prettier, Biome |
| Shell and configuration | ShellCheck, shfmt, actionlint, yamllint, Taplo (TOML), markdownlint-cli2, codespell |

Run `vm profiles install build` on the host to fill missing tools, including new entries in an already selected profile. Python tools live in the default managed environment, so both `ruff` and `python -m ruff` work there. This does not add them to every project environment.

**Each project should declare its own development dependencies and checks.** Follow its lockfile, scripts and configuration. Python test plugins and type checkers often need the project's imports; global JS tools cannot supply the local plugins imported by an ESLint configuration. [uv documents this environment distinction](https://docs.astral.sh/uv/concepts/tools/), and [ESLint recommends installation in the project](https://eslint.org/docs/latest/use/getting-started).

Inside an existing uv project, use `uv sync --locked`, then its documented commands with `uv run --locked`. The default `dev` group is included; select any additional named groups the project uses. For a new project that wants this minimal Python stack:

```sh
uv add --dev ruff mypy pytest
uv run ruff check .
uv run mypy .
uv run python -m pytest
```

Inside an npm project with a lockfile, use `npm ci --include=dev`, then its `npm run lint`, `npm run typecheck` or `npm test` scripts when provided. For pnpm, Yarn or Bun, use the package manager and lockfile already selected by that project. Framework tools such as Vitest/Jest, ESLint plugins, `vue-tsc`, `svelte-check` and `@playwright/test` belong in that project's development dependencies.

Use a project's chosen formatter and lint rules; the toolbox does not require running every checker. It does not create project configurations, install Git hooks or change project lockfiles automatically. Repository package lists resolve current releases when installed; project lockfiles make individual projects reproducible. `vm update` continues to leave developer packages and project environments under their own management.

### Metal

The virtual Mac exposes a Metal GPU even when run headlessly. The `science` profile includes PyTorch with its MPS backend. PyTorch does not automatically move tensors to the GPU; select it in your application:

```python
import torch
device = torch.device("mps")
# For example: model.to(device), inputs.to(device)
```

GPU memory shares physical host RAM. Allocate resources conservatively when running local models on the host at the same time. The menu shows CPU/memory observations; it does not invent a GPU utilization percentage that macOS does not expose reliably for this VM.

## Optional agents and credentials

Install any combination:

```sh
vm agents add pi
vm agents add codex claude
vm pi
vm codex
vm claude
```

`vm agents add` installs or updates only the agents named in that invocation.
Other selected agents keep their versions. If installation fails, staging files
are cleaned and the previous selection is restored; rerun the command to finish
partially installed packages. Regular `vm update` changes managed configuration
and helpers, without reinstalling agents.

Pi has unrestricted native tools. Codex defaults to `danger-full-access` with approvals disabled. Claude Code defaults to `bypassPermissions`. These settings are guest-scoped; they do not change your host agent configuration. Authentication remains user-supplied, and existing guest credentials are preserved on update.

Pi defaults to OpenRouter and `z-ai/glm-5.3`, configurable with `--pi-model`.
New Pi installations offer optional host-held credentials. Enter a key to
enable the relay, or skip and configure any provider normally in Pi; the relay
then stays disabled. Adding Pi later makes the same offer. Use `vm auth set`
to opt in later with hidden key entry and automatic relay setup,
or `vm auth host --from-guest` to move its existing saved key. See
[host-held credentials](CREDENTIALS.md) for lifecycle, copies and other clients.
For ordinary guest-held credentials:

```sh
vm auth guest
# Equivalent:
vm ssh nano /Users/GUEST_USER/.pi/agent/auth.json
```

The guest file is `~/.pi/agent/auth.json`, mode `600`:

```json
{"openrouter":{"type":"api_key","key":"YOUR_OPENROUTER_KEY"}}
```

Keep this file private, never in the repository or public shared folder. `vm auth guest` edits it over SSH without copying it out. Plain `vm auth` selects the host editor when its relay is enabled, otherwise the guest editor. After `vm mount`, the guest file is also accessible under `~/VMs/VM_NAME/Users/GUEST_USER/.pi/agent/auth.json` when hidden files are shown in Finder.

Pi uses [OpenRouter provider routing](https://openrouter.ai/docs/guides/routing/provider-selection) with `zdr: true`, `data_collection: "deny"`, `allow_fallbacks: true`, and `sort: "exacto"`. ZDR restricts eligible endpoints; Exacto ranks eligible providers. There is no quantization filter. If no eligible endpoint is available, the request fails instead of relaxing the privacy policy. ZDR applies to inference endpoints, not to local conversation files or external web searches.

The selected Pi model gets a configurable compaction threshold around 400,000 tokens, reserving 16,384 output tokens and keeping 20,000 recent tokens. The effective model context is capped by the live OpenRouter catalog. If that catalog is temporarily unreachable during configuration, an existing model keeps its saved limit; a new model requires a successful lookup. This is a conservative configuration choice, not a universal retrieval optimum. Other models keep their own context limits. The billion-context extension is not installed.

Pi's web tools use Pi Web Access: Exa, then Parallel MCP, then DuckDuckGo for search; HTTP, Parallel MCP, then Jina for page extraction. A separate `web_browser` tool drives headless Brave when rendering or interaction is needed. Ketch is also available for search, scraping, and code lookup. Ordinary searches do not always launch Google in Playwright. Public search providers can rate-limit or change behavior; browser search can encounter CAPTCHAs. Browser cookies are not copied from your host.

## Privacy, updates, and backups

Managed settings disable diagnostic submission, Siri/Intelligence integrations, personalized advertising, browser metrics/P3A/stats reporting, Homebrew analytics, common developer telemetry, and optional agent analytics/error reporting. Tart tracing variables are removed from managed launches; the optional custom UI build also omits the tracing SDK/exporters. Effective policies are checked inside the guest. This is configuration of known controls, not a promise that every third-party executable makes no network requests.

macOS can clear its managed-preference cache during login. A small guest launch daemon restores these local policies at boot and when the cache changes, with a periodic fallback. It exits after each check and leaves healthy files untouched. The same opt-outs are also written as ordinary machine and user preferences. This is local configuration, without MDM enrollment; it preserves unrelated preference keys.

Brave's adblock component updates and macOS security updates remain enabled. Headless browser profiles have separate storage for different automation clients. The installer does not disable SIP or delete sealed system frameworks. Some VM/hardware combinations are ineligible for Apple Intelligence and have no model downloads to reclaim.

Language and Siri asset directories can also contain spelling dictionaries and other system resources. Feature opt-outs do not promise removal of every system asset. Apple's [macOS 27 guidance](https://support.apple.com/guide/mac-help/mchlb2e44f94/27/mac/27) describes individual feature controls; the installer leaves OS-managed assets intact.

[RemoveMacAI](https://github.com/omlahore/RemoveMacAI) is an optional cleanup tool
for macOS 27 guests that actually have downloaded Intelligence models. It uses
Apple's private asset service to request model removal with SIP enabled, and a
manually approved profile to disable features and redirect model downloads to
a closed loopback port. It does not support macOS 26, and its private API and
download overrides may change with macOS. It is not installed automatically.
Check its `status` first: a guest ineligible for Foundation Models may have no
large model download to remove. Broadly deleting Siri/language directories is
not equivalent. Second Mac's host-side Vision OCR does not require these guest
Intelligence models.

Use the management command from a host terminal:

```sh
vm update --plan                   # Explain the scope; no network access or changes
vm update --check                  # Check Second Mac and VM tools; no guest contact
vm update                         # Update Second Mac and VM tools together; keep guest macOS
vm update --macos --check          # Check Apple's guest update catalog separately
vm update --macos                  # Update guest macOS; may reboot
```

`vm update` treats Second Mac and its VM tools as one installation: the `vm`
command, Tart, Softnet, the VPN networking library if used, guest transport,
host sharing dependencies, and optional
SwiftBar application/integration update together. Guest macOS is a separate
computer's operating system and updates only with `--macos`.

The updater fetches the configured Git upstream, fast-forwards the source,
executes the refreshed code, and installs a complete host runtime snapshot when
its content changes. A running guest receives changed managed configuration and
helpers, including `mac-control`, privacy/shell/tmux settings, and the camera
receiver if already installed. A stopped guest receives those changes at its
next managed start; an unchanged guest is not booted just to update host tools.
The updater does not install optional modules or enable camera, microphone,
guest delegation or permission approval. Documents, credentials, developer
packages, agent versions and guest macOS are retained.

Running VM and SSH sessions stay open. A newer Tart executable activates at the
next cold start; a newly installed guest transport activates at the next guest
boot. New sharing service code takes effect on the next normal VM start.
VPN helpers keep their recorded dependency version on ordinary starts and
code-only updates. A full `vm update` checks for the latest stable library and
builds it only when the version or build inputs changed. Completed binaries
remain immutable: active connections keep their helper until the next network
switch or VM start, and retained copies keep their original version. Native-only
installations do not install a Go compiler just to update an unused helper.
Enabled permission/delegation services reload when host code changes. Updating
Softnet can require host administrator authorization for its replacement
networking executable. Host macOS and macFUSE use their own updaters.
Updates are explicit: pushing to GitHub does not trigger an unattended change
on someone else's Mac.

From the source checkout, `./update.sh` uses exactly the same defaults and flags:

```sh
./update.sh                        # Same as vm update
./update.sh --name agent-box        # Select a configured VM
./update.sh --plan                  # Preview; change nothing
./update.sh --macos                 # Guest macOS only

# Less common choices:
vm update --second-mac-only         # Keep installed Tart and other dependency versions
vm update --configuration           # Apply pending guest changes now instead of waiting for its next start
```

`--second-mac-only` updates Second Mac's code and managed configuration without
upgrading its dependencies. `--configuration` can accompany the default update
or `--second-mac-only`: it starts a stopped VM only when its last successful
receipt shows pending managed changes, then shuts it down again. An
already-running VM stays running.
Content hashes, rather than commit counts or timestamps, identify changed source
and settings, including guest transport releases. Several updates while the guest
is off collapse into one application of the latest configuration on its next
start. Successful components are recorded
in the guest and cached on the host; failed work remains pending for a retry.
Guest startup rechecks its receipt and helper files, including after a snapshot
restore. Unchanged configuration is skipped. Use `vm apply` to deliberately
reapply managed settings after editing them inside the guest.
Suspended guests retain their saved memory even with `--configuration`; managed
guest changes wait until resume. Saved memory keeps its original compatible Tart
executable. Explicit OS maintenance can reboot the guest, so resume important
work and save it before requesting `--macos`.
The guest OS catalog check (`--macos --check`) briefly starts or resumes
an idle guest, without applying pending managed configuration, and returns it to
stopped or suspended afterward. An already-running guest stays running. A failed
catalog scan also restores the prior power state; an actual failed OS installation
is deliberately left running for recovery.
Retained throwaways are excluded, including from deferred startup updates; their
management runtime and guest configuration stay at their saved versions.

Both `vm update` and `./update.sh` reconcile the optional Tart UI build when enabled.
Its cache is keyed by the installed Tart release and the contents of the build
recipe/display sources. Unchanged inputs skip compilation, even if other Second
Mac code changed. Changed inputs build a new executable; a running VM keeps its
existing executable and SSH sessions until its next restart, with an explicit
activation notice. A failed build keeps the previous executable available for
the running VM and can be retried. The default update selects the current stable
Tart release. `--second-mac-only` keeps the installed release and updates our patches.

`vm cache` reports the local Tart compiler caches. Successful `vm update` runs
the same host-only cleanup as `vm cache clean`: remove obsolete releases'
compiler intermediates, retain the caches for configured releases and any
referenced runtime, and keep all finished executables. Busy compilers or an
unreadable reference record defer cleanup without failing the completed update;
retry with `vm cache clean` or the next VM-tools update. Failed updates,
`--check`, `--plan`, `--second-mac-only`, and `--macos` do not run this cleanup.
No macOS restore images, pristine bases, guest disks, checkpoints or saved memory
are deleted. Guest package cleanup remains the guest's responsibility; deleting
guest files uses the ASIF disk's normal automatic space reclamation.

`vm update --macos` runs Apple's guest OS updater without fetching Git or
upgrading Homebrew, Softnet, Tart, or other host dependencies. It reapplies
managed guest settings after a successful OS upgrade and restores the original
running/stopped state. It needs the generated guest administrator password,
supplied automatically; it does not request host administrator authorization.
SwiftBar's **Updates** submenu has **VM tools** and **guest macOS** actions;
there are no separate Second Mac/Tart update controls or build-selection submenu.

`--macos` uses Apple's `softwareupdate` for recommended guest macOS updates and
supplies the generated guest administrator password through standard input.
It does not replace the guest disk or run a fresh macOS installation.
Apple requires a volume-owner account to authorize an Apple Silicon update; the
provisioned guest account has that role. Keep the terminal open during
maintenance. Restarts end current SSH sessions and guest processes. An SSH
disconnect alone is never reported as a successful OS update: a required reboot
must return with a changed macOS build before verification continues.
Older `--system` and `--no-macos` flags remain aliases for the default VM-tools
update. Neither updates guest macOS; use `--macos` explicitly.

**Developer tools, Python environments/packages, project dependencies, browsers, and coding-agent versions are managed inside the guest.** The VM updater does not run their package installers or upgrade commands. Use their own package managers or updaters through `vm ssh`; for example, `vm ssh brew update` then `vm ssh brew upgrade`. Headless Brave's GUI updater is disabled, so explicitly use `vm ssh brew upgrade --cask --greedy brave-browser` for its binary. `vm agents add NAME` remains an explicit way to install/update selected agent modules. Initial installation still resolves current versions from the unpinned package manifests.

Local edits and divergent branches are preserved and stop a Git update;
`--no-pull` deliberately uses the current source for one invocation. A checkout
without an upstream uses its local files and says so. Default `--check` checks
Git metadata, host runtime integrity and VM tool releases without contacting
the guest. Only `--macos --check` starts an idle guest to query Apple's catalog.
`vm apply` explicitly reapplies the current managed guest
configuration without upgrading macOS or restarting an already-running guest.
It starts a stopped guest. An interrupted macOS system update is left running
for recovery; the script does not power it off on an OS-update failure.

The install remains tied to its own checkout, not to the directory from which
you run `vm`:

| Location | Purpose |
| --- | --- |
| `~/.local/bin/vm` | Host command wrapper |
| `~/.local/share/agent-vm/source/OWNER/REPOSITORY` | Default Git source checkout |
| `~/.local/share/agent-vm/NAME/runtime` | Installed snapshot of the same source, checked by hashes |
| `~/.local/share/agent-vm/NAME/config.json` | Private saved settings, including the source checkout path |
| `~/.tart/vms/NAME` | Guest disk and virtual hardware |

Contributors can use their own checkout as the source of truth. From that
checkout, use `./install.sh --source-mode local` at installation, or
`./install.sh --name NAME --source-mode local --update` for an existing setup.
This setting persists: `vm update` and `vm update --check` use local source
without Git fetch/merge, including uncommitted edits. Git commits and pushes
remain your own workflow. `--source-mode git` restores normal upstream updates.
These options select the source policy; the runtime implementation is shared by
both modes. The bootstrap itself is an upstream installer; contributors use the
checkout's `install.sh` directly.

Initial Python installation resolves uv's current download catalog within your chosen selector (`3` by default); an explicit version selector is respected. Later Python and package upgrades belong to the guest's uv workflow. `vm doctor` detects installed-file changes and an available source checkout that has changed since the last host update or apply.

Host macFUSE kernel-driver updates follow its installer/restart procedure;
`vm update` does not replace an active driver used by other host filesystems.

When Time Machine has a configured destination, managed live disks, pristine-cache disks, snapshot disks, and exported backup disk images are excluded. The chosen host shared folder, private management configuration, and the rest of a backup's contents keep their existing backup policies. `vm backup` directly creates its own copy; Time Machine does not make another copy of its large image. No backup history is deleted.

Those exclusions apply to backups on the destination disk. [Apple notes that
excluded files still appear in local Time Machine snapshots](https://support.apple.com/guide/mac-help/exclude-files-from-a-time-machine-backup-mh15622/mac).
Local snapshots can retain older VM blocks after changes or deletion, so deleting
a VM or reclaiming guest space need not immediately free all its host storage.
macOS manages this purgeable space; Second Mac does not delete your snapshot
history. The macOS Storage category “System Data” is broader than VM storage.

### Checkpoints and backups

`vm snapshot` checkpoints are rollback copies stored on the **host**, containing
the guest disk and the settings/credentials needed to restore it. They are
separate from both runnable throwaway VMs and Time Machine's host APFS snapshots;
they do not create another filesystem or macOS installation inside the guest.
Create one before a change you may want to undo, and delete it when no longer
needed. Restoring also saves a `before-restore-*` safety checkpoint. There is no
periodic checkpoint schedule.

```sh
vm stop
vm snapshot create before-change
vm snapshot list
vm snapshot verify before-change
vm snapshot restore before-change
vm snapshot delete before-change
vm backup /Volumes/Backup/agent-box-backup
vm backup --verify /Volumes/Backup/agent-box-backup
vm restore /Volumes/Backup/agent-box-backup
vm apply
```

Create/restore operations require a fully stopped guest and refuse to interrupt SSH. Backups include the guest disk, virtual hardware configuration, NVRAM, and private SSH/administrator credentials. They are private files, not publishable VM templates. SHA-256 verification checks every saved file; large images can take several minutes. Copies use APFS cloning when possible, with ordinary file-copy fallback across volumes, which may need substantially more space.

Restore verifies the source first and saves the current VM as an automatic `before-restore-*` checkpoint. If the VM disk was already lost, it restores directly from the backup instead. An interrupted restore blocks startup until `vm restore --recover` finishes recovery. Restores keep current host file-sharing and port grants. **Shared host project files are not rolled back.** Run `vm apply` after restoring to refresh guest configuration. Backups currently restore into an existing managed configuration with the same guest username; retain the private management state as well for recovery after losing the host.

Local APFS snapshots/clones are useful for rollback but do not protect against losing the host disk. Use `vm backup` on another physical disk for that purpose. Neither snapshots nor backups are created or deleted on an automatic schedule.

## SwiftBar

`vm menubar install` installs the optional [SwiftBar](https://github.com/swiftbar/SwiftBar) integration. The installer selects a current compatible official release, verifies its digest and developer signature, and preserves other plugins. Older builds had disabled submenu actions; the compatibility floor may require a beta until a fixed stable release is available.

The **Updates** submenu separates **VM tools** (Second Mac, Tart and supporting
software) from **guest macOS**. Each has a check and an update action. Regular
versus custom Tart selection is an advanced CLI option (`vm runtime`); the menu
offers available everyday controls without requiring that choice.

The menu is a monochrome icon: a monitor with a power symbol when running, an empty monitor when stopped or suspended. Its menu distinguishes saved memory from shutdown, offers Resume, and separates guest Reboot from Restart VM and macOS. Other actions include shell in the default terminal, tmux sessions, mount/open/unmount, shared-folder access, forwarding, network off/on, and updates. Desktop actions use Show/Hide when available and explicitly name a required restart. Resources includes CPU/memory, disk capacity, host image allocation, and guest free space while running. Disk allocation is visible when stopped too. Agents remain CLI-only. Polling does not start a VM. Actions use ordinary app/file opening and native dialogs; Accessibility/Automation control is not required.

Integration updates preserve unchanged plugin files and refresh only this plugin.
These avoid unnecessary global menu rebuilds; they are mitigations, not a proven
fix for every SwiftBar/AppKit disabled-menu condition.

If actions across multiple SwiftBar plugins become grayed out, restart SwiftBar
to reset its menu state. This leaves the VM and plugin settings unchanged:

```sh
killall SwiftBar
open -g -a SwiftBar
```

## What macOS 27 contributes

The minimum host target is macOS 26. Tart uses the host's system
Virtualization.framework, so host OS fixes apply without bundling an older copy
of that framework. Live validation has been on macOS 27; the installer and test
matrix also target 26, with live guest Settings/permission checks still pending.

| Capability | macOS 26 | macOS 27 |
| --- | --- | --- |
| ASIF sparse disks and APFS clone throwaways | Used | Used |
| Metal, private-channel SSH/files/forwards, native and VPN networking | Same design; no 27-only API required | Used |
| First-time account creation | Guided Setup Assistant, then automatic configuration | Automatic when the guest is also 27+ and Tart supports provisioning; guided otherwise |
| Optional custom display, audio and UI control | Same build options; guest Settings workflows need live validation | Used and validated |
| DiskImageKit stacked disks | Unavailable | Available upstream, unused by Second Mac |
| vmnet loopback port forwarding | No dependency on it | Available upstream, unused by Second Mac |

The macOS 27-specific API actively used is `VZMacGuestProvisioningOptions`, for
the initial guest account and SSH settings. It requires both host and guest 27+
and a Tart build with this option. Existing accounts do not need it. See
[Apple's WWDC26 Virtualization session](https://developer.apple.com/videos/play/wwdc2026/224/)
and [first-boot instructions](INSTALL.md#first-boot-on-macos-26-and-27).
ASIF arrived in macOS 26; Metal support predates it. Host USB integration remains
deliberately disabled.

### Stacked images and independent clones

[DiskImageKit](https://developer.apple.com/documentation/diskimagekit) can combine
an immutable base with writable overlay layers. Reads find the newest version
of a disk block; writes go to the overlay. Multiple VMs can reuse the same base.
An overlay depends on its original base: replacing or updating that base is not
a supported way to upgrade the combined guest filesystem.

Second Mac uses standalone ASIF images and APFS clones. These also share
unchanged physical blocks, while each cloned file remains independently
writable and deletable. Throwaways clone the selected populated VM and inherit
its contents; host shares and grants default to off. A pristine base plus an
overlay would instead start a clean guest, but would not inherit installed tools
or separate copied credentials from other base contents.

To update a stacked design safely, create a new base for future VMs and retain
the old one for existing overlays, or update each guest through its own writable
layer. Neither design provides one macOS update shared automatically by every
existing VM. Independent updates can consume additional blocks. The current
clone design avoids layer-chain management and works on both supported hosts.

### Why ports do not use vmnet loopback forwarding

Apple's [macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)
add loopback support to vmnet port forwarding: a connection from the host to its
own forwarded port can reach the guest through the virtual network. The vmnet
API supports TCP and UDP. Loopback support alone does not guarantee a
localhost-only listener; the forwarding rule has an external port but no
external bind-address argument.

`vm ports` instead explicitly binds TCP listeners to `127.0.0.1` and carries them
through the private Tart channel using SSH. It reaches services bound to guest
localhost, supports explicit host-service grants in the other direction, and
continues working with `vm network off` and across native/VPN mode changes.
vmnet rules depend on the virtual network and do not supply all of those
properties. There is no measured vmnet performance advantage here; a future UDP
or alternate forwarding path would need separate exposure and lifecycle tests.
