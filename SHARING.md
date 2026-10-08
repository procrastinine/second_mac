# Shared files

The default `--sharing hybrid` creates two native folders, plus an optional
linked folder when host macFUSE's kernel backend is already ready:

| Host default | Guest default | Behavior |
| --- | --- | --- |
| `~/vmshare` | `~/shared_files` | Native VirtioFS, writable from both sides |
| `~/vmshare_readonly` | `~/readonly_files` | Native VirtioFS, guest reads only |
| `~/vmshare_links` | `~/linked_files` | Optional scoped macFUSE projection for live symlink exports |

Use the first for projects and valuable files you want on the host. It goes
directly through VirtioFS, without macFUSE or a local duplicate. Use the second
for reference files the guest must not change; read-only access is enforced by
the VM attachment. Use the third to grant access to selected files or directories
elsewhere on the host by creating symlinks. All three can be available together.

If macFUSE is missing or awaiting approval/restart, normal installation proceeds
with the two native folders. `--no-linked-files` always omits the third;
`--linked-files` or an explicit linked-folder path requests it and its dependencies.
The detected choice is saved and preserved on resume/update. After enabling
macFUSE, add the folder with `vm shares configure --linked-files`; remove the
attachment with `vm shares configure --no-linked-files`. Current custom Tart
can apply this live; regular Tart must be stopped first. Existing files stay put.

Names and paths are configurable at installation:

```sh
./install.sh --sharing hybrid \
  --share "$HOME/workspace" --guest-share work \
  --read-only-share "$HOME/reference" --guest-read-only-share reference \
  --linked-share "$HOME/exports" --guest-linked-share linked
```

Without explicit paths, the last two host folders use the primary path plus
`_readonly` and `_links`. The roots must be separate, non-nested directories.
`vm shares` lists the configured mapping; `vm access` distinguishes it from
current attachments. SwiftBar's **Host folders** submenu opens
each host folder. An existing installation retains its previous sharing mode
on update. Use the same options with `vm shares configure`. With current custom
Tart, it unmounts without force, changes attachments, remounts, and retains SSH.
Close files and leave working directories inside the affected mounts first;
busy mounts reject the change. Failed changes roll back the previous mapping.
With regular Tart, stop first; configuration briefly starts the guest to apply
its mounts and returns it to stopped. No files are moved or packages reinstalled.
Saved-memory guests must resume before their sharing configuration can change.

**Native folders do not filter or redact symlinks.** A host symlink's target text
is visible to the guest, possibly including a host username. Links resolve in
the guest namespace; linking to an unshared host target does not export it.
Put host export links in the linked folder. Normal development symlinks within
native folders remain usable. No watcher attempts to enforce this convention.

macFUSE is installed **only on the host**, and only the linked folder passes
through it. The guest uses macOS's built-in VirtioFS client for all three mounts.
The host projection runs without root while the VM is in use, has no listening
network socket, and stops when the VM exits. Files stay in their original host
location; the projection does not mirror them. Its additional filesystem layer
costs more for small files and metadata-heavy work than native VirtioFS.

Host Time Machine coverage depends on where the actual bytes live:

| File location | Host Time Machine coverage |
| --- | --- |
| Ordinary file in a native host shared folder, including one created by the guest | Follows that host folder's existing backup policy |
| Original host file exported through a symlink in the linked folder | The target's real location must be included; backing up the symlink alone does not include its contents |
| File stored only on the guest disk | Not included through host sharing; the managed VM image is excluded |
| Guest disk mounted in Finder, or guest file symlinked into a shared folder | Mounting/linking does not bring the guest contents into the host backup |

There is no automatic guest backup or local mirror. External/network targets
keep their own backup requirements. See [checkpoints and backups](GUIDE.md#checkpoints-and-backups)
for the existing, separate manual stopped-VM backup command.

## Export a file or project

On the host:

```sh
ln -s "$HOME/projects/example" "$HOME/vmshare_links/example"
ln -s "$HOME/Documents/reference.pdf" "$HOME/vmshare_links/reference.pdf"
```

The guest accesses `~/linked_files/example` and
`~/linked_files/reference.pdf`. Export aliases appear as ordinary directories
or files. Edits are written back to the originals. Host source paths and the
host account name are not returned through those aliases' symlink contents.
Chosen files can, of course, contain identifying information themselves.
Targets must be accessible to the host account and filesystem service under
macOS file permissions and privacy controls.

Remove an export on the host with `rm "$HOME/vmshare_links/example"`. This removes
the symlink, leaving the original project intact. New uncached lookups no longer
find the alias. Cached directory entries and existing open file descriptors can
remain available; VirtioFS can retain backing handles after an application
closes a file. Shut down the VM to revoke all such handles.

## Scoped symlink behavior

The following applies to the linked folder, not the two native folders.

| Link | Guest behavior |
| --- | --- |
| Relative link within the shared tree | Ordinary POSIX symlink |
| Absolute host link to another item within the same shared tree | Equivalent relative guest symlink, without the host path |
| Host-created file/directory link outside the linked folder | A writable export of that selected target |
| Link inside an exported project that escapes that project | An unavailable link; its source path is hidden |
| Missing external target | An unavailable link; other files and VM startup remain usable |
| Missing internal target or internal link cycle | Ordinary dangling link or loop behavior |
| Guest-created link, including virtual-environment executables | Preserved literally and resolved in the guest |

Guest-created links carry a private filesystem attribute so they cannot become
host export grants after a restart. The guest cannot read, remove, or forge
that attribute. Do not strip extended attributes from live shared symlinks on
the host: that discards their provenance. Host backup/copy tools should preserve
extended attributes. This is an additional reason to stop the VM before restoring
a shared tree from a backup.

`--no-external-links` disables external export grants while retaining ordinary
internal and guest-created symlinks. It still uses the projection to translate
absolute internal host paths safely. The installer never silently falls back
to sharing raw host paths if the projection fails.

Manage host-created links and directories containing them on the host. Guest
renames of those entries are refused to prevent a relative link from granting
a different host target after a move. Guest-created links and ordinary project
files can be renamed normally. Directory renames and hard links across separate
exports return a cross-device error.

## Scoped filesystem semantics

The projection supports direct file reads and writes, execute permissions,
symlinks, hard links within one export, file attributes, and `fsync`. Editor
atomic-save renames onto an exported file replace the selected original while
preserving its host alias. As with other filesystems, cross-device renames may
return `EXDEV`; applications must perform their usual copy fallback.

Concurrent writes to the same bytes have normal filesystem race semantics;
sharing does not merge conflicting edits. Use an application's atomic-save or
locking protocol. Guest root does not become host root, and setuid/setgid bits
are stripped from the projected view.

Cross-boundary advisory locks are not a verified coordination mechanism. Open a
database from one side at a time. For metadata-heavy dependency caches, guest-local
storage can be faster; builds and virtual environments inside the share are also
supported and covered by the development integration check.

Native VirtioFS is the preferred live share for development. Guest-local APFS
avoids filesystem sharing overhead entirely. For a linked project, or when
metadata traffic dominates, keep source shared and put generated output on the
guest disk where the build tool supports it. For example, inside the guest:

```sh
cmake -S "$HOME/linked_files/project" -B "$HOME/.cache/build/project" -G Ninja
cmake --build "$HOME/.cache/build/project"
```

Substitute the configured guest share name and project directory. This keeps one
working copy of the source and does not mirror datasets. Generated output in the
guest is outside the host shared-folder backup; keep irreplaceable results in
the shared folder or back them up separately.

If the projection process fails, access fails instead of exposing raw host paths.
Use `vm restart` to recreate the host view and guest mount. A normal VM exit
removes the projection automatically, including abrupt Tart process termination.

## External drives and mounted filesystems

An export can select a nested directory on an external drive or another mounted
filesystem. The backing filesystem must be mounted and accessible to the host
account. Mount it on the host, then symlink only the selected directory into the
linked folder. No remote-service credentials are copied into the guest by this
operation.

Live checks on macOS 27 covered these arrangements:

| Backing filesystem | File editing, atomic replacement and concurrent writes | Symlinks within the selected directory |
| --- | --- | --- |
| External APFS volumes | Passed | Relative/absolute host links and guest-created links passed; escapes blocked |
| rclone through macFUSE, local backend, `--links --vfs-cache-mode full` | Passed | Relative host links passed; absolute-link metadata and guest-created links were limited by the backend |
| SSHFS through macFUSE, macOS SFTP server | Passed | Relative host links passed; absolute-link metadata and guest-created links were limited by the backend |
| Native SMB mount, macOS server | Passed | Relative/absolute host links passed; guest-created links were refused because required symlink metadata was unsupported |

The network tests used controlled local servers. They do not certify every
cloud provider, NAS, SSHFS option, non-APFS drive format or network-outage case.
The projection cannot add POSIX capabilities missing from a backing filesystem.
In particular, safe guest-created symlinks require symlink metadata handles,
extended attributes and atomic publication. Unsupported operations fail instead
of silently losing the distinction between a guest link and a host export grant.
Use APFS or guest-local storage for builds that depend on those operations.

Nested host links are still confined to the selected export: a link to an
unselected sibling or parent does not grant access. Export that other target
explicitly from the host if it is needed.

Stop the VM before unmounting a backing drive/share if it reports that it is
busy. VirtioFS's retained handles can otherwise keep it mounted. A cloud-backed
mount's successful write or `fsync` is not proof that upload has completed;
[rclone's VFS cache](https://rclone.org/commands/rclone_mount/#vfs-file-caching)
can defer writeback until files are closed and its configured delay has elapsed.
Keep the backing mount running until its own pending transfers finish.

## Host dependency

Install current [macFUSE](https://macfuse.github.io/) and follow its
[kernel-backend setup](https://github.com/macfuse/macfuse/wiki/Getting-Started).
On Apple Silicon this can require Recovery-mode authorization of third-party
kernel extensions and a restart. The installer does not change Startup Security,
SIP, or Gatekeeper for you. No FUSE package is installed inside the guest.

The kernel backend avoids FUSE-T's additional network-filesystem translation.
Actual development performance depends on metadata traffic, file size, caching,
and the extra VirtioFS boundary; an upstream backend claim is not a benchmark
of this complete arrangement.

## Single-folder and disabled modes

`--sharing native` attaches only `--share` directly through VirtioFS. It
requires no macFUSE, host Python projection, or filesystem service. Ordinary
files, guest development workflows and relative links within the folder work;
`--share-read-only` works too.

`--sharing macfuse` retains the original single-folder arrangement: all of
`--share` goes through the scoped projection. `--share-read-only` makes that
whole folder read-only, including linked targets. `--sharing none` disables all
host folders and is always used for throwaways. The default hybrid arrangement
already includes a dedicated read-only native folder; `--share-read-only` is
only for the single-folder modes. No mode silently falls back to another.

## Access guest files from the host

`vm mount` mounts the guest's `/` at `~/VMs/VM_NAME` using native macOS SMB over
Tart's private channel. It uses authenticated, encrypted SMB without an extra
SSH tunnel. The host listener binds only to `127.0.0.1`; host/LAN network
restrictions stay in place. The relay starts on mount and ends on unmount or VM
exit. A busy unmount fails visibly instead of forcing open files off the mount.

This is a filesystem mount, so Finder and ordinary host tools can access guest
files without keeping another working copy. It is not reverse VirtioFS and
does not provide guest-local APFS performance. SCP/SFTP remain available for
copies through the SSH alias. SSH terminal sessions and selected port forwards
continue to use their existing private transport.

The supported installation uses no FSKit extension, signing account, FUSE-T, or
WebDAV service.

## Local project tools

Run `vm projects setup ~/vmshare/example` on the host to configure a shared pnpm, npm, or uv workspace. The command installs small command adapters and private settings in each account, without adding files to the project. It starts the guest if necessary, supports different absolute project paths, and can be repeated for other projects or to refresh the installed adapters. Open a new shell afterward. `vm projects list` shows registrations; `vm projects remove PATH` removes a registration while retaining installed dependencies and environments.

For pnpm, this supplies a stable pathname for each Mac's independent package cache, disables the global virtual store for that project, and keeps `verifyDepsBeforeRun=error`. Existing dependencies need one `pnpm install --force` to adopt that cache; subsequent installs, updates, and runs use ordinary pnpm commands. Before scripts run, a local presence/version check uses pnpm's own dependency listing and its explicitly skipped platform packages to catch damaged transitive packages that its fast pre-run check can miss. The installed pnpm remains responsible for lockfile, release-age, trust, build-script, and dependency verification. No tool or dependency version is pinned or overridden. Source and installed packages may be shared when the OS, CPU architecture, and required native runtime ABI are compatible; upgrade incompatible runtimes together and reinstall affected native dependencies.

For uv projects, use normal `uv sync` and `uv run` commands. `UV_PROJECT_ENVIRONMENT` selects a separate environment per project in each account. Python installations and the wheel/download cache are shared through standard `UV_PYTHON_INSTALL_DIR` and `UV_CACHE_DIR` settings. A usable existing `.venv` is retained by one account; the other gets its own environment. Other existing environments are left in place. Shared `.venv` directories are not generally portable: interpreter links, console-script paths, and editable installations can contain machine-specific absolute paths. Environment-specific scripts and editable paths remain separate, with uv using its normal clone/copy installation policy. npm needs no cache-path adapter; it continues using its normal commands and local cache.

Some mounted macOS filesystems reject `F_FULLFSYNC` while supporting `fsync`. Setup probes the actual project filesystem and, only where needed, builds a small compatibility library. The adapter loads it into the selected package-manager process: an unsupported full-flush request performs a real `fsync`, and write errors still propagate. The library does not carry into child applications. This also avoids rebuilding or pinning package-manager binaries after updates.

Settings and helpers live under each account's `~/.config/project-tools` and `~/.local/share/project-tools`. Guest-installed files contain only local paths and neutral project-tool names. Commands outside registered projects retain their usual behavior. Setup changes configuration only; dependency installation and updates remain explicit. It does not make simultaneous installs into the same dependency tree safe; serialize those writes as for any shared checkout.

### Updating from either Mac

Package managers remain independently installed on each Mac; project manifests and lockfiles are shared. Use the ordinary commands below from either account. No automatic update, version pin, or machine-specific setting is added to the project.

| Intent | Command | What the other Mac does |
| --- | --- | --- |
| Update pnpm itself | `pnpm self-update` | Keeps its own pnpm until you run the same command there; the adapter discovers the new executable automatically. |
| Update pnpm project dependencies | `pnpm update --latest` | Compatible shared packages are immediately usable. If validation reports stale or damaged state, run `pnpm install --frozen-lockfile` to accept the shared lockfile without selecting newer releases. |
| Update npm dependencies | `npm update` | Uses the shared installed tree. `npm install` reconciles a manifest/lockfile change; `npm ci` deliberately replaces the tree. |
| Update uv project dependencies | `uv lock --upgrade` then `uv sync --locked` | `uv sync --locked` accepts the shared lockfile into its own environment. Normal `uv run` also reconciles that environment; `uv run --locked` additionally prevents lockfile edits. |
| Update Python or a package manager installed by Homebrew | `uv python upgrade`, `uv self update`, or `brew upgrade TOOL`, as appropriate | Shared managed Python patches are reusable; tools installed separately are updated separately. Homebrew-owned uv directs self-updates to Homebrew. |

An incompatible Node/native-addon ABI or CPU architecture still requires matching runtimes or rebuilding the affected dependencies. Keep shared-tree installs sequential. To preview reconciliation without changing the installed environment, use `pnpm install --frozen-lockfile --dry-run` or `uv sync --locked --dry-run`. To inspect before accepting an update, use `git diff -- package.json pnpm-lock.yaml pyproject.toml uv.lock` and the package manager's normal list/outdated commands. A validation failure stops execution and identifies the repair command; it never silently ignores missing packages or rewrites the lockfile to make a run pass.
