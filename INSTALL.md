# Installation

[Project overview](README.md) · [Using Second Mac](GUIDE.md) · [Feature guide](FEATURES.md)

You need an Apple Silicon Mac running **macOS 26 or later**, an administrator account, internet access, and sufficient free disk space for Apple's restore image and the selected guest tools. The default VM has 4 CPUs, 8 GiB RAM, and a 100 GB sparse disk. Leave at least 4 GiB RAM available to the host. Existing installations keep their resources and tools.

Run as your ordinary Mac account. This installs the base tools with no coding agents:

```sh
curl -fsSL https://raw.githubusercontent.com/procrastinine/second_mac/main/bootstrap.sh | /bin/bash
```

Put optional modules and settings at the end of the same command:

```sh
curl -fsSL https://raw.githubusercontent.com/procrastinine/second_mac/main/bootstrap.sh | /bin/bash -s -- \
  --name agent-box --user developer --profiles web,science --agents pi,codex --menubar \
  --share "$HOME/my-share" --guest-share shared_files
```

Omit `--profiles` for the base tools and `--agents` for no agents. Use `--profiles full` for the complete developer suite, or `--agents pi,codex,claude` for all three optional agents. CPU, RAM, disk and other choices use the same options as `./install.sh --help`. No API keys are accepted on the command line. To inspect the bootstrap before running it, [read bootstrap.sh](bootstrap.sh), or use the local-checkout instructions below.

Selecting Pi offers optional host-held OpenRouter credentials. Enter a key
privately, or approve using an existing key in
`~/.local/share/agent-vm/credentials/openrouter.key`. Accepting with a key
enables the relay and configures Pi to use it. Press Return to skip and set up
your preferred provider normally in Pi; unattended setup also skips this offer.
Skipping leaves the relay disabled, even if a host key is later supplied for
another VM. No key goes in the command or shared folder. Run `vm auth set`
later to opt in with hidden key entry and automatic Pi setup.
Use `--host-credentials none` to skip the offer, or
`--host-credentials openrouter` to explicitly select host setup, including
without Pi. If no key is supplied, that setup also stays disabled. Saved choices
survive retries and updates. Adding Pi later with `vm agents add pi` makes the
same offer; updating an existing Pi keeps its choice. [Credential setup](CREDENTIALS.md).

Add `--ui` for guest-only clicks, typing, OCR and permission workflows. Its local
Tart build runs alongside macOS image preparation, then both finish before the
first guest boot. Build output is kept in private installation state. A completed
build or OS image is reused after an interruption. Ordinary desktop show/hide
does not require this option. Selecting `--ui` also starts the guest's
`mac-control` service whenever the VM starts; `--no-guest-control-autostart`
keeps UI control host-only. Automatic dialog approval remains a separate,
disabled option. Both the credential relay and control service stop with their
VM, including guest shutdown, suspend and a Tart crash. Throwaways start with
both grants off and can be enabled individually.

SwiftBar's **Services** menu and the [service commands](CREDENTIALS.md#host-service-startup)
let you start/stop either service for the current VM run and independently
choose its autostart behavior. Each service manages its own private tunnel;
ordinary port forwarding stays separate.

The optional runtime's source checkout is published only after its release tag
has been verified. An interrupted clone is retried automatically; it does not
leave a partial checkout that needs manual deletion.

The bootstrap installs missing host Command Line Tools and [Homebrew](https://brew.sh/) from their official installers, then clones the repository's current default branch into `~/.local/share/agent-vm/source/OWNER/REPOSITORY`. It retains that normal Git checkout so `vm update` can fetch later changes. Rerunning fast-forwards a clean checkout and refuses to overwrite local edits. `--ref BRANCH` selects a maintained branch; versions are not frozen. `--checkout PATH` changes the source location; `--repo OWNER/REPOSITORY` selects a fork. `--plan` previews the bootstrap without downloads or installation. No full Xcode application is needed. The guest's Command Line Tools and Homebrew are installed automatically too.

The default creates native writable and native read-only folders. It also creates a scoped linked folder **if host macFUSE's kernel backend is already ready**. Otherwise setup proceeds with the two native folders, without installing macFUSE or requesting its approval. This choice is saved: resuming or updating never silently adds or removes a folder. `--no-linked-files` always omits it; `--linked-files` explicitly requires it. Add it later with `vm shares configure --linked-files` after enabling [macFUSE](https://github.com/macfuse/macfuse/wiki/Getting-Started); regular Tart must be stopped first. Explicit linked-folder setup installs missing dependencies and can require host approval/restart. macFUSE and its private Python environment are needed only on the host, only for that folder. See [SHARING.md](SHARING.md) for the different symlink/privacy behavior.

If you already cloned the repository and have Homebrew/host Command Line Tools, enter its directory and run as your ordinary Mac account:

```sh
./install.sh --plan --name agent-box --user developer \
  --cpus 4 --memory 8 --share "$HOME/vmshare" --guest-share shared_files

./install.sh --name agent-box --user developer \
  --cpus 4 --memory 8 --share "$HOME/vmshare" --guest-share shared_files \
  --menubar
```

`--plan` only prints the configuration. Omit `--menubar` for command-line-only management. Add `--agents pi,codex,claude` to select agents during installation, or add them later. Run `./install.sh --help` for all options, including disk capacity, timezone, Python selector, and Pi model/compaction settings. Use `--ipsw /path/to/restore.ipsw` to reuse a compatible local restore image instead of downloading it again.

The guest automatically logs into its configured account. Use `--no-autologin`
to disable this, including when configuring a guest with FileVault; the installer
does not turn off encryption. These settings apply only inside the guest.

The installer downloads the latest official Tart and guest-agent releases, verifies their published SHA-256 digests, and verifies Tart's code signature. Softnet comes from `openai/tools/softnet`. It needs host administrator authorization to configure networking; the installer checks and sets the executable's root ownership and setuid permission. A Softnet upgrade can require this again for its new executable. Terminal installs use `sudo`; other invocations show the standard macOS authorization prompt. Canceling leaves setup resumable. The guest gets a generated password and a dedicated SSH key. Neither is hardcoded or put in the shared directory.

First installation reuses a compatible pristine local OS cache when available, otherwise downloads and installs macOS. It installs only selected tool profiles. You can rerun the same command after an interruption; managed state records its progress. On a completed VM, rerunning reapplies configuration without reinstalling macOS or guest packages. Using an existing unmanaged Tart VM name is rejected. A different username requires a new VM configuration. Change sharing with `vm shares configure` (see [SHARING.md](SHARING.md)); use `vm resources` while stopped to change CPU, RAM, or disk capacity. Add modules later with `vm profiles add` and `vm agents add`. Updates retain saved settings.

### Resume an interrupted installation

Rerun the original one-command installer with the same options. Once its source
checkout exists, `./install.sh --name NAME` from that checkout also resumes using
the saved choices. A missed administrator prompt, unfinished CLT installation,
network failure, or host/guest shutdown does not require deleting the VM or
starting with a new name. Complete any pending Apple/macFUSE approval and rerun.
The installer checks that the selected compiler tools and Homebrew actually
work; a partially present directory does not count as a completed dependency.

Private settings and credentials are saved before host setup. Retries preserve
the password and SSH private key and recover a missing public-key file from the
private key. Guest base setup, tools, finalization, file access, and login each
have completion checkpoints. A failed stage is retried; finished stages are
skipped. A guest setup process that is still running blocks a competing attempt
until it exits. If only host command/menu setup failed, the retry handles that
stage without entering the guest again. Previously booted guest disks are never
silently recreated when missing.

Apple's initial restore is an exception to exact progress resumption.
[Tart publishes the VM only after the restore succeeds](https://github.com/openai/tart/blob/main/Sources/tart/Commands/Create.swift).
If interrupted before that point, the restore stage can restart using a
completed IPSW in Tart's cache. Tart may restart an incomplete download; deleting
its cache can require another download. The selected restore URL and build are
saved before downloading, so a retry does not switch versions mid-install.
After the installed disk exists, retries keep it and continue guest setup.
An actual power loss can also require filesystem/package-manager recovery;
checkpoints do not repair disk corruption or bypass macOS consent.

### First boot on macOS 26 and 27

`--setup auto` is the default. If both host and selected guest run macOS 27 or
later, and the selected Tart executable exposes Apple's provisioning API, the
installer creates the guest account and enables Remote Login automatically.
Otherwise it opens the guest's Setup Assistant. This also works with regular
Tart; no custom build is needed for guided setup.

For the guided path:

1. Complete Setup Assistant in the guest window. Use the exact **account name**
   printed by the installer (`--user`, default `agent`) and choose a guest
   password. Skip migration and Apple Account sign-in, and decline analytics,
   Siri and Apple Intelligence.
2. In the guest, open **System Settings → General → Sharing → Remote Login** and
   enable it for that account.
3. Return to the installer terminal and enter the guest password when prompted.
   Input is hidden; the password is stored only in private installation state.
   The installer continues with tools, privacy settings and the private
   connection, then closes ordinary network SSH access.

The host clipboard stays unshared. The installer waits up to 30 minutes for
Remote Login; if you stop, close the guest or take longer, rerun the same command
in Terminal. It reuses the existing disk and completed stages. A confirmed
password is retained; a rejected one can be entered again on the next retry.
`--setup manual` explicitly selects this path even on macOS 27.

The default `latest` selector and local IPSWs provide version metadata. An
explicit IPSW HTTPS URL with unknown guest version uses guided setup rather
than assuming it supports the provisioning API. No second download is made to
inspect it. `--from-vm` keeps the existing account and skips first-time setup.

macOS 26 is a compatibility target; live end-to-end validation has been on
macOS 27. Automated checks cover version selection, guided setup retries and
credentials, with CI jobs for macOS 26 and the current macOS runner. Guest
Settings/permission workflows still need live macOS 26 validation. See the
[platform differences](GUIDE.md#what-macos-27-contributes).

### Reuse local images

`./install.sh --images` or `vm images` lists pristine caches and existing managed guests. Fresh OS installation saves a private, unbooted base image before account provisioning. With the default `--ipsw latest`, each new installation queries Apple's latest compatible restore-image metadata and reuses a cache only if its recorded macOS version/build, host major version and disk capacity match. This metadata query does not download another macOS image. Older caches and legacy caches with no recorded build are not silently selected. `--fresh` bypasses caches; an explicit local IPSW or `--from-vm` deliberately selects your existing image. Reused pristine images receive new virtual machine identifiers and fresh guest credentials. APFS clone copies avoid duplicating unchanged blocks; retaining a cache can retain blocks that a guest later deletes.

Apple's latest compatible restore image can differ from its Software Update
catalog. Use `vm update --macos` for subsequent OS patches. Resuming an existing
installation keeps its selected image and disk instead of starting over when
Apple publishes a new version.

These are independent copy-on-write disks, not a shared OS that updates in place for every guest. Updating a VM leaves its pristine cache unchanged and can retain older OS blocks. Updating two clones independently can allocate duplicate blocks even when their version numbers match. There is no automatic disk rebase or persistent-state migration across macOS versions.

To deliberately copy a populated, stopped managed guest without reinstalling macOS:

```sh
vm stop
./install.sh --name second-box --from-vm agent-box --share "$HOME/second-share"
```

This copies that guest's documents, installed tools, accounts, and credentials. It preserves the guest username and tool selections. It creates a separate disk and defaults to a separate host shared folder; existing host port grants are not copied. It never silently chooses a populated guest as the base for a new installation. Unmanaged Tart and Lume images are not automatically imported: Virtualization.framework images also need compatible hardware identity, NVRAM, disk format, and configuration. A shared framework alone does not make their directory formats interchangeable.

The installer adds `vm` to `~/.local/bin`. If that directory is missing from the
host's current `PATH`, it configures the detected shell (zsh, Bash, fish, or
sh/ksh) automatically. It also sets up `brew shellenv` when Homebrew's environment
is missing, before any existing shell framework or completion setup. It does not
replace your completion configuration. Existing startup settings and symlinks are preserved;
original files are backed up in private VM state. Repeating the installer does
not duplicate its PATH block. It honors `ZDOTDIR` and `XDG_CONFIG_HOME` when set.
Other shells receive manual setup instructions.

Homebrew analytics are disabled during installation and persistently with
[`brew analytics off`](https://docs.brew.sh/Analytics) on the host and guest.
The bootstrap installs missing Apple Command Line Tools using `softwareupdate`
and selects them with `xcode-select`; full Xcode is unnecessary. If Apple's
catalog does not offer CLT, it gives instructions for `xcode-select --install`
and rerunning the bootstrap. Guest macOS and optional tool privacy settings are
applied automatically inside the guest; the host's macOS preferences are left
under the host user's control.

Open a new terminal afterward, or enable it in your current zsh/Bash terminal:

```sh
export PATH="$HOME/.local/bin:$PATH"
vm status
vm ssh
```

The equivalent repository-local entry point is `./agent-vm`. `vm --name another-box status` selects another managed VM. `--no-integrations` skips adding host commands, shell PATH settings, and an SSH alias. `AGENT_VM_HOME` can select a different private host state directory.
