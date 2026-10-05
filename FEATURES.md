# What Second Mac adds to Tart

Second Mac turns Tart into a persistent second computer for personal use:
an everyday shell and occasional desktop, with explicit choices about which
files, services and devices it can reach on your personal Mac. This page collects
the additions in one place, including optional features and their limits.

Tart supplies the virtualization engine, virtual graphics, image operations,
VirtioFS sharing and network attachments. Its [upstream run command](https://github.com/openai/tart/blob/2.40.1/Sources/tart/Commands/Run.swift)
already includes graphical/headless modes, Softnet integration and suspend
support. Second Mac adds configuration, lifecycle coordination, daily controls
and an optional custom build. The upstream comparison here uses Tart **2.40.1**;
installation and updates still select current stable releases.

**Custom build** below means the optional Tart build compiled locally by Second
Mac. It requires no Apple Developer account. Networking, SSH, Finder access,
ordinary sharing and most management features work with regular Tart.
Advanced build selection stays in `vm runtime`; SwiftBar shows everyday actions.

[Daily access](#everyday-access-and-a-quick-menu) · [Desktop and media](#desktop-audio-and-camera) · [Permissions](#guest-ui-and-permission-automation) · [Suspend/resume](#suspend-resume-and-fewer-restarts) · [Networking](#network-boundaries-that-work-with-daily-host-use) · [Files](#live-files-with-three-distinct-sharing-choices) · [Storage and copies](#storage-retained-copies-and-backups) · [Setup and maintenance](#installation-privacy-tools-and-maintenance) · [Costs and limits](#costs-and-limits-to-plan-for)

## Everyday access and a quick menu

| Addition | What it does |
| --- | --- |
| One-command shell | `vm ssh` starts the guest if needed and connects without looking up its IP. `vm ssh COMMAND`, `vm sudo COMMAND` and `vm cp` cover command execution, administration and transfers. |
| Command discovery | `vm help COMMAND` and nested `--help` explain arguments without loading or starting a VM. Bash/zsh Tab completion suggests commands, flags, choices, snapshots and copy IDs from local state only. |
| Private SSH transport | SSH uses Tart's VirtIO channel and the guest's loopback SSH server. Wi-Fi changes, guest DHCP and turning external networking off do not remove this path. Dedicated credentials replace password entry; the host SSH agent and keys are not forwarded. |
| Sleep-friendly SSH settings | Disabled heartbeat/idle expiry lets host sleep pause the existing transport. It targets the same connection surviving wake, without keeping the host awake. Actual lid-close survival needs the per-machine `vm check-sleep` test; it is not guaranteed. |
| Agent-friendly tmux | `vm tmux` creates or attaches sessions. Mouse scrollback, Option-click support, large history, extended keys, activity indicators and explicit clipboard copying are configured. Tmux remains optional for ordinary shells. |
| Password and login convenience | A generated guest administrator password, `vm password` to copy it to the host clipboard, and optional native automatic desktop login. Automatic login does not unlock a manually locked desktop. |
| Access report | `vm access` shows configured and actually attached shares, forwarded ports, media and guest-control grants; JSON output is available. |
| SwiftBar | A monochrome status icon, start/stop/reboot, suspend/resume, show/hide desktop, shell, tmux sessions, Finder mounts, shared folders, networking and forwards. Resources include CPU/memory and storage; retained copies have their own controls. Polling never starts a stopped VM. |

The menu has one update/check pair for **VM tools** and another for **guest
macOS**. It does not ask users to manage Second Mac and Tart separately.
Guest-side convenience commands use **`mac-control`**, keeping them distinct
from the host's `vm` command.

## Desktop, audio and camera

| Addition | Availability and interruption |
| --- | --- |
| Desktop on demand | `vm gui` shows the desktop and `vm gui --hide` hides it while shells and background work continue. Regular Tart starts with a hidden native window ready to show. After a strict headless start, creating a viewer live requires the **custom build**; regular Tart needs a cold restart. No VNC server is enabled. |
| No idle host rendering with the custom build | Hidden means the view is disconnected from the VM, with its window removed from display. Opening the GUI attaches it live; screenshots/OCR attach it only for the request. Guest graphics and Metal remain available. Visible viewing and active capture still have a resource cost. |
| Close without stopping work | Closing the **custom build's** viewer hides it. With regular Tart, use Hide instead of closing its window. |
| Output-only audio | `vm audio on` lets the guest play through host speakers/headphones, including headlessly, with no host microphone source. Requires the **custom build**. Attaching/removing audio takes effect at the next cold start; `--restart` explicitly applies it now. |
| Live mute/unmute | `vm audio mute` and `vm audio unmute` change guest playback without restarting when output is already attached. This changes guest volume; it does not revoke the audio device. |
| Independent microphone opt-in | `vm microphone on/off` selects host-default microphone input separately from playback. Requires the **custom build** and a cold start to change the attached device. Host consent remains manual. |
| OBS Virtual Camera bridge | `vm camera on/off` shares the host's composed OBS Virtual Camera video as a guest camera. Its guest setup uses the **custom UI controller**. After setup, the bridge starts/stops live; extension installation may require guest logout/reboot. It never falls back to the physical webcam, screen or microphone. |

Playback, microphone and OBS camera are off on new installations until selected.
The camera bridge follows the VM's lifetime and uses its private channel without
opening a video port. OBS chooses the scene; audio is a separate option.

Upstream Tart's [audio configuration](https://github.com/openai/tart/blob/2.40.1/Sources/tart/VM.swift#L324-L339)
couples host input and output and disables passthrough in suspendable mode. The
addition here is independent media control, especially output without recording
the host, rather than audio support itself.

## Guest UI and permission automation

The optional **custom UI controller** provides screenshots, clicks, key presses,
typing and local Apple Vision OCR through `vm ui`. It runs in the host VM
process and addresses only that guest's display and virtual input devices.
It needs no guest UI server, host Accessibility control or guest screen-recording
permission. OCR needs no LLM, API key, cloud service or Apple Intelligence model
download.

- **One-shot consent:** `vm ui approve` approves a recognized guest permission
  dialog. `vm ui inspect` and `vm ui click-text` support explicit UI workflows.
- **Automatic consent:** opt-in `vm permissions auto on` watches recognized
  guest dialogs while that VM runs, including supported LuLu connection alerts.
  It captures and recognizes the guest screen, waits five seconds, then repeats.
  This consumes CPU and briefly attaches the renderer even with the viewer
  hidden. It is off by default and stops when the VM stops.
- **Settings workflows:** `vm permissions grant`, `check` and `revoke` manage
  supported guest app permissions. SIP-on workflows cover Accessibility,
  screen recording, Input Monitoring and Full Disk Access. Camera/microphone
  switches require the app to have requested access first.
- **Extension workflows:** commands handle supported installed camera, network
  and filesystem extensions by their visible app label. They do not install
  arbitrary extensions or make unsupported guest kernel extensions work.
- **Guest SIP management:** explicit `vm sip off/on` automates paired Recovery
  and verifies the result after boot. It changes only guest SIP and requires
  reboots. Its separate Recovery controller is built automatically; restoring
  Full Security also uses custom Tart and Apple's signing service.
- **Direct permission records:** an alternative for supported signed guest apps
  when guest SIP is already off, with private database backups. SIP remains on
  by default; turning it off is not a prerequisite for ordinary UI approval.
- **Delegation to an agent:** host-authorized `vm guest-control on` lets guest
  software call `mac-control approve`, `inspect`, `grant` and related UI commands.
  New installs selecting `--ui` enable autostart; opt out with
  `--no-guest-control-autostart`, or choose `on --once` later. Access uses a per-run token,
  is revoked at shutdown, and cannot enable itself.

Delegation covers only guest UI and supported app permissions. It has no host
filesystem or arbitrary-command API, and cannot change sharing/network grants,
host media, SIP or VM lifecycle. Guest apps can still edit files already shared
with them. Retained copies start with delegation and automatic approval off.

These are deterministic English UI workflows, not a universal consent API.
The guest desktop must be logged in and unlocked; typed input assumes printable
ASCII and a US keyboard. Unrecognized screens are not automatically approved. Automatic
approval is a broad opt-in convenience, not an application security policy.
The input controller uses version-sensitive private framework interfaces;
host permission prompts are never automated.

## Suspend, resume and fewer restarts

Second Mac wraps Tart/Virtualization.framework save and restore with sharing
cleanup, service lifetime management, recovery records and menu controls.

| Operation | Result |
| --- | --- |
| `vm suspend` | Saves guest memory, processes and tmux, exits Tart, and releases host CPU/RAM. Saved memory uses additional disk space. |
| `vm resume` or `vm start` | Resumes that memory with the original compatible executable and virtual hardware. Shell and SwiftBar Resume actions use the same path. |
| `vm reboot` | Reboots guest macOS, keeping the Tart process when possible. Guest processes and SSH end. |
| `vm restart` | Cleanly shuts down and restarts both Tart and macOS. This activates queued virtual-hardware or executable changes. |

Managed starts support suspend/resume with regular Tart when compatible;
the **custom build** validates saves, writes through a temporary checkpoint and
retains compatible devices. Busy shared files prevent suspension instead of
being forcibly unmounted. Failed or interrupted restores retain recovery state;
they do not silently boot a fresh guest or discard saved memory.

Saved memory is private, excluded from Time Machine and removed after successful
restore. Resource changes, disk copies and restore operations reject suspended
disks. Resume preserves guest processes, **not a promise that the host's existing
SSH connection survives**; `vm tmux` reattaches to the preserved session. Host
lid sleep is the separate case described above.

Showing/hiding the desktop, UI enable/disable on a prepared custom build,
network changes, port forwards, audio volume and supported folder changes happen
live. Updates prepare new executables without replacing a running VM. Device
changes are queued unless a restart is explicitly requested. The complete
[restart matrix](CAPABILITIES.md#feature-matrix) distinguishes a live change,
Tart-only replacement, guest reboot and a cold restart of both.

## Network boundaries that work with daily host use

- **Host/LAN isolation:** managed Softnet restrictions block ordinary access to
  the host and local networks; host interfaces and connected network ranges are
  included. The guest gets no blanket access to host localhost.
- **VPN-aware networking:** automatic mode follows host route changes and uses
  a compatible host-socket backend when needed. Native mode keeps its normal
  data path without adding the VPN backend's packet-processing overhead.
- **Live switching:** `vm network auto`, `native`, `vpn` and `refresh` change
  networking without rebooting Tart or macOS. Internet connections can reconnect;
  private SSH, Finder transport and explicit forwards stay available.
- **Network off:** `vm network off` disconnects external Ethernet traffic while
  retaining SSH and explicit forwarded ports. `on` restores the previous mode.
- **Explicit localhost grants:** `vm ports host PORT` exposes one host service
  to guest localhost; `vm ports guest PORT` exposes one guest service to host
  localhost. TCP mappings persist, bind only to loopback and stop with the VM.
- **DNS that follows the backend:** guest DNS is reconciled with the active
  network path instead of forcing a fixed external resolver through every VPN.

These features use regular Tart; the network supervisor does not require a
custom build. VPN detection cannot infer every split-tunnel or per-app policy,
so an explicit `vpn` choice remains available. Second Mac does not alter host
firewall/VPN rules or promise per-guest-process attribution in a host firewall.

## Live files with three distinct sharing choices

| Share | Added workflow |
| --- | --- |
| Native writable | A host folder for projects and valuable guest-created files, with one local working copy and direct VirtioFS access. No macFUSE overhead on this path. |
| Native read-only | A separate reference folder the guest cannot modify through its attachment. |
| Scoped linked files | Optional host macFUSE projection: symlink a selected host file/directory into the export folder and work on it live in the guest. Only that selected tree is exported; host path text is hidden through those aliases and nested escapes are blocked. |

Every host path and guest folder name is configurable. Installation proceeds
with native folders when macFUSE is unavailable; add the linked folder later.
macFUSE runs only on the host, with no file server listening on a network port,
and follows the VM's lifetime. Native shares retain ordinary literal symlinks;
they do not filter or hide target text. Use the linked folder for external grants.

Linked-file edits write back to the originals. Deleting the host export symlink
removes the reference, not its target; already-open/cached handles can survive
until shutdown. In the scoped projection, guest-created links cannot turn
themselves into new host export grants. External drives and mounted filesystems can be selected, subject to
their own permissions and supported filesystem operations. The scoped layer
costs extra for metadata-heavy builds; native sharing or guest-local build
outputs remain available without mirroring source/data.

The **custom build** can change folder roots, names and access modes live,
with busy-mount checks and rollback. Regular Tart requires shutdown for those
attachment changes. Ordinary file edits and adding/removing linked exports
are live with either build.

For access in the other direction, `vm mount` mounts guest **`/` in Finder**
using authenticated, encrypted SMB through Tart's private channel. Mount/unmount
and file browsing need no guest LAN exposure or SSH file tunnel. The relay ends
when the VM stops. This is separate from host-to-guest VirtioFS sharing.

## Storage, retained copies and backups

- **Resource controls:** `vm resources` reports CPU/RAM allocation, sparse-disk
  capacity, allocated host blocks and saved-memory space. CPU/RAM and supported
  ASIF disk growth are validated while stopped; shrinking capacity is refused.
- **Space accounting:** sparse ASIF disks reclaim discarded guest blocks through
  the underlying platform. Successful VM-tools updates automatically run the
  host cleanup available as `vm cache clean`, removing obsolete compiler
  intermediates while retaining finished executables, current/referenced build
  caches and guest storage. Guest cleanup is managed inside the guest.
  APFS copies and snapshots can retain older blocks.
- **Retained throwaways:** `vm throwaway` creates an independent APFS clone of
  the stopped main guest, assigns an ID and optionally runs a script. No new
  macOS download is needed. Copies remain until explicitly deleted and appear
  in SwiftBar. Their local writes do not change the main guest's disk.
- **Separate grants for copies:** host shares, forwards, media and delegation
  are off by default. Copies keep their saved software/configuration instead
  of receiving main-VM updates. They inherit the source guest's files and
  credentials; they are not pristine or isolated from effects on remote accounts.
- **Checkpoints and recovery:** explicit stopped-VM snapshots, checksum-verified
  backups, restore rollback and interrupted-restore recovery through `vm`.
- **Time Machine policy:** when configured, large managed disk images and saved
  memory are excluded; throwaway state is excluded too. Ordinary host shared
  files keep their existing backup policy. A symlink target needs coverage at
  its real location; a Finder mount does not enroll guest files in Time Machine.

There is no automatic guest-file backup or second local mirror. APFS cloning,
sparse storage and memory saving are platform capabilities; Second Mac adds the
commands, state checks, exclusions and lifecycle integration around them.

## Installation, privacy, tools and maintenance

| Addition | Included behavior |
| --- | --- |
| One-command, resumable setup | Install missing host Homebrew/Command Line Tools, add `vm` to PATH, resolve VM dependencies, provision the guest and install its tools. Interrupted stages can be retried; existing completed work and credentials are retained. Names, resources, shares and modules are configurable. |
| Reuse and parallel work | Reuse a compatible pristine local OS cache or explicitly clone a populated managed VM. Optional custom compilation runs alongside macOS image preparation. A populated guest is never silently treated as a clean image. |
| Minimal base, optional tools | Developer profiles cover Python/science, JS/TS, build/checking tools, browser automation, media, documents and optional LaTeX. Shell PATH, completions, tmux and privacy settings are configured. Project dependencies remain project-local. |
| Optional agents | Install Pi, Codex or Claude Code during setup or later; none is installed by default. Adding a module changes only the named agents. Selected agents get guest full-access configuration and supported privacy settings. Shared writable host files remain writable by those agents. |
| Pi conveniences | Pi Web Access search/extraction fallbacks, headless Brave interaction with adblocking, and Ketch as another tool. OpenRouter requests require ZDR and disallow data collection, with Exacto provider ordering; context compaction is configurable. Credentials can stay guest-private or use the optional host relay. |
| Host-held model credentials | Pi installation offers optional host-key setup; skip to configure Pi normally with the relay disabled. `vm auth set` opts in later; `vm auth host --from-guest` moves Pi's saved OpenRouter key. A thin streaming relay substitutes it for a local guest credential. No key means no server. Independent current-run and autostart controls, automatic tunnel lifecycle, and opt-in for throwaways work with regular Tart. No body inspection or model-policy rewriting. [Details](CREDENTIALS.md). |
| Privacy defaults | Disable supported diagnostic/analytics settings, Siri/Apple Intelligence features and known tool telemetry; preserve security updates. Managed privacy settings are repaired when macOS rebuilds them. Host clipboard/USB integration is disabled; host home and credentials are not automatically shared. |
| Custom-build cleanup | The optional Tart build removes OpenTelemetry exporters/resource collection and argument tracing, and omits an unused formatter build dependency. Release and patch inputs determine the cache; unchanged inputs do not compile again. |
| Unified updates | `vm update` and `./update.sh` update Second Mac, Tart, supporting VM tools and SwiftBar together. Stopped/suspended guests remain idle; changed guest helpers/settings apply on the next start. Several updates collapse into the latest required configuration. |
| Separate guest OS maintenance | `vm update --macos` uses the existing guest administrator credential, verifies a required reboot by the changed OS build, and preserves the previous power state after success. Failed OS installations remain available for recovery. Developer packages and agent versions use their own updaters. |
| Shared implementation and diagnostics | New installs, updates and the installed commands use the same source. Runtime manifests and guest receipts detect drift and pending work. `vm doctor`, `vm logs` and guest `mac-control help/doctor` expose the relevant state without installing development demos or personal notes. |

macOS 26 is the minimum host target for ASIF storage. Automatic first-boot account
provisioning requires macOS 27 on both host and guest; the installer otherwise
uses a [guided Setup Assistant step](INSTALL.md#first-boot-on-macos-26-and-27).
GPU/Metal access comes from Tart and Virtualization.framework; Second Mac does
not add a GPU driver or force every PyTorch operation onto MPS. Supported science
tools are available through their profiles. Privacy opt-outs do not remove every
OS-managed asset or prevent agents from sending selected content to their model
and search providers during normal use.

## Costs and limits to plan for

- **Hidden is not stopped.** Custom Tart disconnects the viewer when closed,
  hidden or minimized. Guest apps, WindowServer and GPU work can still run.
  SwiftBar samples a running guest every 30 seconds; optional automatic consent
  performs screenshot/OCR work. Neither polling path boots a stopped guest.
  The first OCR request can take tens of seconds; later requests are usually
  much faster. Disconnected view objects and framework caches remain in memory
  until Tart exits.
- **Suspend trades RAM for disk.** A memory checkpoint consumes additional host
  storage and is tied to a compatible host/runtime. It preserves guest processes,
  but SSH must reconnect. Close files in shared mounts before suspending.
- **Clones save space initially.** Divergent writes and independent macOS upgrades
  allocate more blocks. Old copies or APFS snapshots can prevent space being
  reclaimed after deleting guest files. A retained throwaway inherits guest
  files, credentials and cloud logins; disk independence does not isolate remote
  accounts. Its saved tools and runtime do not receive main-VM updates.
- **Sharing is an explicit grant.** Writable shared files can be deleted by guest
  software. Removing a linked export prevents new uncached lookups but does not
  revoke existing handles; stop the VM for complete revocation. Native shares
  preserve literal symlink text. Linked shares have additional metadata cost.
- **Network off preserves explicit access.** SSH and configured TCP forwards
  still work. VPN routing and traffic blocking follow the host VPN's policy.
  Automatic backend selection does not bypass that policy or independently
  require a VPN when the host allows ordinary internet access. Per-app and
  split-tunnel policies need their own verification.
- **Backup policy follows actual storage.** VM images and saved memory are
  excluded from Time Machine when configured. A linked target needs backup
  coverage at its original location; mounting the guest in Finder does not
  enroll its contents in host Time Machine.
- **Privacy settings have a scope.** Supported telemetry is disabled, but macOS
  security services and software that the guest runs can still contact the
  internet. Optional permission automation can approve guest-rendered dialogs;
  it is a broad convenience grant, not per-app authorization.

For setup, see [Installation](INSTALL.md); for exact command options, see
[Using Second Mac](GUIDE.md).
[CAPABILITIES.md](CAPABILITIES.md) details restart/build requirements,
[SHARING.md](SHARING.md) defines filesystem and backup behavior, and
[SECURITY.md](SECURITY.md) describes the boundaries. [TESTING.md](TESTING.md)
records verified behavior and remaining limits, including physical sleep/media
tests. [COMPARISON.md](COMPARISON.md) covers Lume/Cua and disposable-VM tradeoffs.
