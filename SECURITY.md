# Security and privacy boundaries

Second Mac is for a persistent personal VM with explicit access to selected
host files and services. It relies on macOS Virtualization.framework, Tart,
Softnet, macFUSE and SSH. It has not received an independent security audit.

## Host access

Both native Softnet and the VPN-compatible host-socket backend block the host
and configured private/connected IPv4 networks, link-local addresses, multicast
and guest IPv6. The guest uses the host's outbound connection; this is not
anonymity, and VPN coverage follows the host's routing and firewall policy.
Automatic mode selects a compatible backend from the host's public IPv4 route;
it does not exclude the helper from the VPN or override the VPN's traffic blocks.
The host VPN remains responsible for its kill-switch/lockdown policy. Second Mac
does not independently require a VPN: when the VPN is intentionally disconnected
and the host permits ordinary internet access, the guest can use that access too.
Selecting `vpn` chooses host sockets; it does not create a tunnel. Split-tunnel
and per-app VPN policies need their own verification. Explicit network grants
are loopback TCP forwards managed with `vm ports`. While the VM runs, a
three-second watcher checks host addresses and connected subnets, refreshing
restrictions even if the backend stays the same. `vm network refresh` requests
an immediate refresh. Detection is polling-based, not an atomic firewall update
at the instant a host interface changes. Switching helpers can interrupt internet
connections; the independent VirtIO SSH transport remains available.
Clipboard, audio, USB passthrough,
SSH agent forwarding and X11 forwarding are disabled by default. Optional host
media sharing is described below; clipboard copies remain explicit commands.

`vm clipboard to-guest` and `to-host`, and the host's SwiftBar **Clipboard**
submenu, copy a single plain-text snapshot in the requested direction over the
existing SSH transport. `--no-clipboard` stays enabled. There is no clipboard
watcher, inbound clipboard service or guest-control clipboard operation. Menu
refreshes do not read either clipboard. `vm password --guest` sends only the
stored guest password, without reading or replacing the host clipboard.
Transfers are limited to 1 MiB of UTF-8 text, with bounded subprocess output
and timeouts. Contents travel through private pipes, never command arguments,
logs or temporary files. The source is validated before the destination is
changed. Destination applications can read text after a transfer; copying does
not automatically paste, execute text or press Return. Existing clipboard
history tools and terminal OSC 52 settings remain independent of these controls.

The default creates native writable and read-only host folders, plus a scoped
linked folder when host macFUSE is ready. Otherwise the linked folder is omitted
without installing a driver; the saved choice changes only explicitly. Native shares pass
symlinks literally, including any host paths in their target text; there is no
symlink ban or path-redaction filter. Read-only access is enforced by the VM
attachment. The linked folder exports selected targets without their source
paths or unselected parents/siblings; guest-created links there cannot grant
new host exports. [SHARING.md](SHARING.md) defines the scope, revocation and
extended-attribute provenance. The host home directory is not shared by default.

Finder access to the guest uses authenticated, encrypted SMB over Tart's private
channel, without an SSH tunnel. Its host TCP relay listens only on loopback and
stops on unmount or VM exit. It grants no guest network access to host services.

Writable shares give guest software permission to change or delete those files.
Their contents can include names, secrets and other personal data; source-path
translation does not redact contents. Removing an export stops new uncached
lookups, but cached entries and already-open handles can remain usable. VirtioFS
may retain backing handles after an application closes its file. Stop the VM to revoke
all such handles. Guest root remains subject to the host account's permissions.

## Accounts and credentials

Each new pristine VM gets a random administrator password and dedicated SSH
key. SSH does not copy the host's keys, agent socket, browser cookies or home
configuration into the guest. Explicit populated-VM cloning and backups copy
existing guest data and credentials; they are private recovery artifacts.

Host management state lives under `~/.local/share/agent-vm` by default and is
separate from this repository. Guest credentials and tool configuration live
in private files inside the VM. Backups are not encrypted by this project; use
encrypted storage when needed. Automatic login is enabled by default and uses
macOS's recoverable credential file. Use `--no-autologin` to disable it. FileVault
and SIP are never turned off by the installer.

Optional `vm ui` control runs on the host and addresses only the VM's own display
and virtual input devices. Capture is restricted to the controller process's
own window; input is not posted to the host. No guest UI helper or host/guest
Accessibility permission is needed. The local control socket is owner-only,
checks the connecting UID, exposes a fixed set of display/input operations, and
is not shared or forwarded to guests. It is not a general host command API.
Private Virtualization.framework input interfaces are version-sensitive.
OCR uses local Apple Vision; it is independent of Apple Intelligence downloads
and never sends guest screenshots to a model service.

Optional `vm guest-control on` delegates a subset of that controller and guest
app permission management to the configured guest account through its
`mac-control` command. The host keeps the separate `vm` management command. A separate HTTP
service binds only to host loopback; a dedicated reverse forward listens only
on guest loopback. Requests require a random per-run bearer token, JSON with
bounded size, and a fixed operation schema. Browser-origin requests are refused.
There is no endpoint for host commands/files, changing network or sharing
rules, selecting another VM, SIP changes, or VM lifecycle control. All UI input
targets the same guest virtual devices, including keyboard input into guest
apps. Any software able to read the guest account's private token can use this
capability; it is not per-app authorization.

Pointer targets are bounded to the guest screenshot; drag duration and scroll
distance are bounded, and each gesture releases its buttons on completion.
`mac-control paste` is an explicit guest-local clipboard write followed by a
virtual Cmd-V. It leaves the guest clipboard set, never reads the host clipboard,
and introduces no clipboard endpoint. Input text is supplied on stdin to the
clipboard helper, never as subprocess arguments. Screenshot files written by
the helper use mode 0600. Installing its skill only copies instructions.

The service checks the owning VM process and host authorization, stops with
its private forward when the VM exits, and rotates credentials each managed
start. Autostart is opt-in and scoped to one VM; `on --once` instead grants access
only for the current running VM process. `vm guest-control off` disables future
starts, revokes new requests and removes the endpoint;
previous grants remain and already issued actions may finish. The client and
an unusable old token may remain in the guest. Throwaways omit the delegation
setting, automatic approval and host token state. They inherit the guest client
file like other disk contents; first-start setup removes its copied capability,
and its old token cannot authorize the source VM's next run.
Guest control cannot enable itself or disable SIP to make direct grants work.

Guest SIP can be changed explicitly with `vm sip off/on`. These commands boot
that VM's paired Recovery without shares and verify SIP after normal boot.
SIP disabling is offline; restoring Full Security uses the selected isolated
network backend for Apple's signing service, with host/LAN access blocked.
They do not change host SIP. `vm permissions` uses guest Settings for supported SIP-on grants;
direct modification of guest TCC records requires guest SIP off. No guest
database is treated as a host database. Protected, unreadable records are
reported as unavailable rather than interpreted as a denial.
Automatic guest consent approval is opt-in and broad: software inside that VM
may gain access to more guest data, including writable shared files it can
already reach. OCR can misclassify guest-rendered content; it is a convenience
within the VM boundary, not a trustworthy permission policy engine. Disabling
automatic approval retains existing grants.

Host microphone and OBS camera sharing are separate opt-ins, disabled on new
installs and throwaways. Guest-control cannot enable them. OBS video selects only
the configured OBS virtual-device identity; it has no physical-camera, screen or
audio fallback. A small host capture app needs host Camera consent, distinct
from the permission-free guest UI controller. Host consents are never automated.
The video pipe uses Tart's private guest channel and opens no listening port.
Its capture app follows a per-run generation and owner lock so disabling the
bridge, stopping the VM or losing the owner terminates capture. Microphone
passthrough is a virtual-hardware change and requires a VM restart.

The custom runtime's management socket is host-only and separate from the guest
UI endpoint. Live attachment changes, memory saving and runtime selection are
never delegated to `mac-control`. Disabling UI automation live revokes scripted
input/capture/OCR while retaining ordinary desktop show/hide.

Optional agents run with unrestricted guest tools. Their privacy controls
reduce known telemetry; they do not prevent code, prompts or selected files
from being sent to a model or web provider during ordinary use. Pi's ZDR routing
covers model endpoints, not external web searches. Provider policies and your
own credentials still apply.

The optional [OpenRouter credential relay](CREDENTIALS.md) keeps the upstream
key in a private host file. The guest holds only a local relay token. The relay
uses a fixed HTTPS destination, passes bodies unchanged, and stops with the VM.
It does not enforce ZDR, a model allowlist or a spending budget; Pi's configured
provider policy and the key's OpenRouter limits still apply. A permitted guest
can use that key's API authority while the relay is enabled. It remains usable
with guest Ethernet off, through its explicit private-channel forward.
Throwaways do not inherit this host grant. Moving a previously guest-held key
does not erase copies in older disks or backups.

## Disk copies

Saved guest memory can contain passwords, tokens and open documents. It is kept
in private host storage with mode 0600, excluded from Time Machine, and removed
after verified resume. Treat it like the guest disk: protect the host account
and use host disk encryption. It is coupled to the same disk and compatible
runtime; disk-only copying, resizing or restoration is refused while suspended.
Failed memory operations retain recovery state and never intentionally fall
back to a new boot. Upstream Tart's save failure handling is less protective
than the custom controller: it can exit the process after a save error. Save
important work before suspending, particularly before a host OS update.

A copy-on-write clone initially contains the source disk's readable contents.
It isolates later writes; it does not remove documents, credentials, logs or
other existing data. Disabling host shares or hiding a guest home directory
does not sanitize a populated VM. Guest administrator access must not be
treated as restricted to one home directory.

`vm throwaway` deliberately uses this populated-copy model. It omits host
shares and inherited port grants, uses an independent disk, and retains the
copy until explicit deletion. Existing credentials remain usable against
remote services. Cloud synchronization and remote account changes can affect
other computers even though the local VM disks are separate.

A clean installation cache is captured before account provisioning or personal
use. It is separate from populated guests, backups and checkpoints. Only a
clean source can provide a starting point that has never contained the
persistent guest's private data. Independently updating cloned disks can
allocate additional OS blocks; the current implementation does not rebase
existing guests onto an updated cache.

## Updates and reporting

Installers fetch current upstream releases. Tart, the guest transport and
SwiftBar downloads use published SHA-256 digests; Tart and SwiftBar signatures
are checked. Package managers retain their own trust and update mechanisms.
The optional UI extension instead builds the matching official Tart source tag
locally, records its upstream revision and binary digest, and uses an ad-hoc
virtualization signature. It is not an upstream signed release binary. Cached
build dependencies follow upstream's Swift package lockfile.
`vm update` refreshes Second Mac, Tart, Softnet, the guest transport and SwiftBar
together; managed guest settings/helpers update while running or on the next
managed start. `--second-mac-only` keeps the installed dependency versions.
`vm update --macos` separately updates guest macOS without upgrading host
dependencies. Developer packages and agents remain managed in the guest.

When reporting a bug, provide a minimal reproduction and relevant error text.
Review logs before sharing them: they can contain local paths, VM names,
selected filenames or upstream output. Do not attach VM disks, private state,
backups, SSH keys or authentication files. The repository tests check common
publication hazards, but they are not a substitute for reviewing a diff.
