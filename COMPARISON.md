# How Second Mac compares

The goal is one personal Mac and one persistent Mac for software you want to
keep separate: agents, unfamiliar applications, or commercial software you do
not trust with your personal files. You decide which files and localhost services
cross that boundary. This is a configuration and
management layer over existing virtualization tools, not a new hypervisor.

## What it adds to a plain Tart installation

The complete inventory is in **[What Second Mac adds to Tart](FEATURES.md)**:
desktop and independent audio controls, guest UI/permission automation,
coordinated suspend/resume, network and file boundaries, SwiftBar, retained
copies, privacy defaults, installation and maintenance. It distinguishes
regular-Tart features from custom-build additions and states the interruption
and opt-in requirements.

Tart supplies the VM engine and underlying platform capabilities. Other projects
offer many of these conveniences individually. The value here is their combined
policy and everyday workflow; writable shared files remain subject to an
agent's changes. This page focuses on alternative runtimes and usage models.

## Why macOS instead of a Linux container

The reason is to run actual Mac software separately from your personal Mac:
commercial applications, a second browser environment, native command-line
tools, and agents building and testing the same macOS software you use. A Mac
guest provides Apple's frameworks, Xcode tooling, application permissions and
desktop behavior. Cross-compiling some binaries elsewhere does not replace
running them on macOS.

Metal/MPS access is useful for Mac-native workloads, but it is not a claim that
every Linux container lacks GPU access. Projects such as
[Lighter](https://github.com/fieldwork-ai/lighter) provide Linux-to-host GPU
bridges; their compatibility and performance are separate questions, not
benchmarked here. There is also no general CPU-speed advantage claimed over a
hardware-virtualized ARM Linux guest.

For Linux services, container images and deployment environments, existing
Linux tools are usually the more direct fit. Even the isolation comparison
depends on the implementation: [Apple's container tool](https://github.com/apple/container)
runs Linux containers in lightweight VMs. Second Mac does not need to manage
Linux to serve its purpose; it focuses on a personal second **Mac**.

Persistent tools and in-place guest OS updates are useful parts of that daily
workflow, but other persistent VM managers can provide them too. The project's
case is the combination of selected file/port access, privacy defaults,
optional host-held credentials, desktop and permission controls, suspend,
SwiftBar and coordinated updates around one durable computer.

## Tart and Lume

[Lume's CLI](https://cua.ai/docs/reference/lume/cli-reference) supports attaching
a viewer to a running VM, including a native viewer with VNC fallback. That is a
real advantage over Tart's strict `--no-graphics` mode. With regular Tart,
Second Mac keeps Tart's native window hidden on normal starts, then shows/hides
it without a VM restart. That path uses a graphical application throughout.

Optional custom Tart creates its viewer live after headless startup and detaches
the host renderer when the viewer is hidden.
`vm ui enable` adds guest-only screen/input control to that runtime and keeps
its virtual display available for show/hide.
It needs neither a guest UI server nor host Accessibility control. Its private
Virtualization.framework input interfaces add maintenance risk; this is not a
claim of a more stable or complete computer-use API than Cua/Lume.

Both use Apple's Virtualization.framework and VirtioFS. The
[Lume virtualization implementation](https://github.com/trycua/cua/blob/main/libs/lume/src/Virtualization/VMVirtualizationService.swift)
uses NAT/bridged networking. Moving this setup would need equivalent host/LAN
isolation and a replacement for its existing VirtIO SSH transport. No such
migration is implemented or claimed verified here. The scoped symlink projection
is a separate filesystem layer; changing the VM manager does not provide it or
establish a sharing performance advantage.

Cua's [file API](https://github.com/trycua/cua/blob/main/libs/python/computer-server/computer_server/handlers/base.py)
offers programmatic reads/writes, including base64 binary transfers over its
WebSocket connection. Lume's [desktop transfer helper](https://github.com/trycua/cua/blob/main/libs/lume/src/SSH/SystemSSHClient.swift)
uses SCP. These are useful transfers, not reverse VirtioFS mounts of the guest
disk. Second Mac's Finder mount uses native SMB over Tart's private channel;
host-to-guest shared folders use VirtioFS. No Cua-versus-Second-Mac performance
benchmark is claimed.

The VM disk, NVRAM and machine identity are conceptually reusable, but directory
schemas, disk formats and configuration differ. There is no tested Tart-to-Lume
conversion command in this repository. Cua/Lume may be a better starting point
when their viewer, API, or
computer-use integration is the main requirement; this repository focuses on a
person managing a persistent second computer.

## Storage and disposable guests

APFS clones share unchanged blocks, as described in
[GhostVM's cloning documentation](https://ghostvm.org/docs/vm-clone). They are
independent disks: installing packages or updating macOS consumes additional
space. Matching OS version numbers do not make independently written blocks
shared. Choosing another VM manager does not by itself establish an upgrade or
migration scheme that keeps one physical copy of all OS data.

`vm throwaway` copies the current stopped guest, including its tools, files and
credentials. Host shares and port forwards are absent. Copies receive short
IDs and remain available until explicitly deleted, including after failed
scripts. This uses the same general cloning model as GhostVM; it does not
provide a pristine environment or conceal the source guest's existing data.
New copies inherit the source's current macOS without another download. Older
retained copies can keep older OS blocks alive. There is no automatic migration
between OS generations.
## GUI control code reuse

[Cua](https://github.com/trycua/cua) includes macOS mouse, keyboard and scrolling
drivers. Second Mac adapts its move/down/interpolated-drag/up gesture plan and
pointer priming for scroll, delivering events through the VM's virtual devices.
The adapted code records its upstream revision in `lib/display/Pointer.h` and
retains the [Cua MIT license](lib/third-party/CUA-LICENSE.txt).

[Peekaboo](https://github.com/openclaw/Peekaboo) offers richer Accessibility
targeting, screenshots and clipboard workflows; [cliclick](https://github.com/BlueM/cliclick)
offers compact macOS mouse/keyboard commands. Their native OS input routes need
permissions on the Mac they control. Second Mac keeps its existing VM backend,
Apple Vision OCR and automated guest Settings workflows, so these extra controls
need no additional GUI server, model downloads or host Accessibility grants.
Guest-local explicit paste covers Unicode without granting access to the host
clipboard. These tools remain useful for applications needing deeper semantic
Accessibility automation inside a guest.
