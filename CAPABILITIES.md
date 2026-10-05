# Runtime capabilities and lifecycle

For the complete inventory of additions over Tart, see [FEATURES.md](FEATURES.md).
This page details their build requirements and lifecycle behavior.

Second Mac prefers ordinary Tart features. Custom Tart adds controls that the
upstream CLI does not expose. `vm runtime` reports both the selected runtime for
a future cold start and the capabilities of the **actual running process**.
Updating commands does not upgrade a running Tart process or retained throwaway.

## Four different operations

| Operation | Tart process replaced? | Guest macOS boots again? | Running guest work |
| --- | --- | --- | --- |
| Live change | No | No | Kept; the changed service itself may be interrupted |
| `vm reboot` | Normally no; detected and reported if Tart exits | Yes | Ends, including tmux and SSH |
| `vm suspend`, then `vm resume` | Yes | No | Guest memory, processes and tmux preserved; reconnect SSH |
| `vm restart` | Yes | Yes | Ends, including tmux and SSH |

A normal Tart exit loses live guest memory. Saving and restoring memory is the
specific exception; restarting a host networking helper or SwiftBar is also
independent of restarting the VM. A host macOS reboot is a separate operation.

## Feature matrix

“Both” means a cold start of Tart **and** guest macOS. A saved memory resume uses
the original compatible hardware and executable; it does not apply queued device
changes or activate a different Tart release.

| Feature or change | Regular Tart | Custom Tart | Smallest required interruption |
| --- | --- | --- | --- |
| SSH, new shells, tmux attachment, SCP | Supported | Same | None |
| Forward/remove selected TCP ports; Finder mount/unmount | Supported | Same | None; removing a forward closes that forward |
| OpenRouter host-key relay on/off; rotate its upstream key | Supported | Same | No VM restart; reopen an existing Pi once when switching credential modes. Revocation interrupts its model requests. |
| Native / VPN networking selection | External Second Mac supervisor | Same | None for VM/SSH; external internet connections may reconnect |
| Network off/on | Ethernet disabled independently of private SSH and forwards | Same | None for VM/SSH/forwards |
| Edit native shared files; add/remove scoped host symlinks | Supported | Same | None |
| Change folder roots, names or read-only policy | Shut down first | Live, with rollback and non-forced unmounts | Both for regular; none for custom, but close busy shared files first |
| Show/hide a prepared desktop | Live; a hidden native window is prepared by default | Live; closing, hiding or minimizing disconnects the host rendering view | None |
| Show a desktop after strict headless launch | Cold restart to attach native window | Can create its display live | Both for regular; none for custom |
| Guest-only keyboard, pointer, screenshots and Apple Vision OCR | Not exposed by regular Tart | Supported | Custom runtime needed; enabling/disabling its controller is live |
| Automatic permission approval / guest delegation | Requires custom UI controller | Start/stop live, scoped to this guest | None; affected guest apps may need reopening |
| Guest permission grants/revocations | Requires custom UI controller | Supported deterministic workflows | Usually none for OS/runtime; some extension categories require a guest reboot |
| Guest playback volume, mute/unmute | Live if output attached | Same | None |
| Attach/remove host audio devices | Upstream couples input/output | Independent playback and microphone | Both; settings queue for next cold start unless `--restart` is explicit |
| Output-only audio | Not exposed by regular Tart | Supported, no host input stream/source | Both to attach initially; volume then live |
| OBS camera bridge on/off | Requires custom guest UI setup | Bridge changes live after setup | No VM restart; installing the camera extension may require guest logout/reboot |
| CPU count / RAM / main system disk growth | Stopped VM | Same | Both; suspended memory must first resume and shut down |
| Suspend/resume guest memory | Managed starts without microphone use upstream `--suspendable` | Uses Apple's save/restore validation and retains compatible devices | Tart replacement only; guest boot, tmux and processes kept |
| Select standard/custom/auto runtime | Saves next cold-start choice | Same | None now; both when activating a different executable |
| Update Second Mac commands, SwiftBar, managed guest helpers | Live, or deferred until guest start | Same | None; installed guest transport changes activate at the next guest boot |
| Update Tart / Softnet | Builds/downloads while VM keeps running | Same | Tart activates on a future cold start; networking helper can change live |
| Update guest macOS | Apple Software Update | Same | Guest reboot when Apple requires it; runtime is relaunched only if it exits |
| Change guest SIP | Offline Recovery workflow | Same | Both, including Recovery boots |
| Create retained throwaway, disk checkpoint, backup or restore | Requires cleanly stopped source/destination | Same | Both if it was running; never snapshot a suspended disk independently of its memory |
| Install developer tools or optional agents in guest | Supported | Same | None unless the particular installer requires it |
| Install/enable host macFUSE kernel extension | Optional, only for scoped linked folder | Same | May require a **host** macOS restart; native folders work without it |

An old running custom build can lack newer controls. Commands refuse unsupported
live operations rather than quietly restarting it. SwiftBar checks actual
capabilities and preserves each throwaway's saved implementation.

`vm update` updates Second Mac and its VM tools together without restarting
the guest. The separate rows above describe when each component takes effect,
not separate routine update commands. Guest macOS requires `vm update --macos`.
SwiftBar offers these two choices; advanced Tart build selection stays in the CLI.

## Runtime selection

```sh
vm runtime                         # selected vs running, plus available controls
vm runtime --json
vm runtime standard                # use regular Tart at the next cold start
vm runtime custom                  # build if needed; use at the next cold start
vm runtime auto                    # custom only when selected features need it
vm runtime custom --restart        # explicitly end sessions and switch now
./install.sh --runtime custom       # first-install choice
vm update --runtime standard       # change choice while updating management code
```

Standard mode retains custom-feature preferences so switching back is easy.
Native GUI, sharing, isolation, VPN switching, SSH and forwards work with either
runtime. Automatic mode selects custom Tart for UI automation or independent
audio. Custom builds use an upstream **release tag**, never HEAD, and rebuild
only when the selected release or patch inputs change.

## Saved memory

`vm suspend` writes a private `state.vzvmsave` alongside the VM disk, then exits
Tart and releases CPU/RAM. It costs additional disk space for saved memory, not
a second macOS installation. The file is excluded from Time Machine and deleted
after successful restore. Shared files remain subject to their normal host
backup policy.

`vm resume`, `vm start`, Shell and the SwiftBar Resume action restore saved
memory. Busy shared files must be released before suspension: the guest's
managed mounts are unmounted without force and remounted after restore. This
avoids preserving stale handles to a restarted macFUSE projection. Do not modify
the VM disk while it is suspended. Resource changes, copies and disk backups
reject suspended VMs.

The saved launch record pins the original executable and checks virtual hardware
and sharing before restoring. Updates may prepare a newer build, but it takes
effect after a clean shutdown. A failed restore never falls back to a cold boot
or silently deletes saved memory. `vm stop` resumes a suspended guest before
shutting it down cleanly. A saved-state file is not a portable backup: Apple ties
it to its host and compatible configuration, and some host OS changes can make
it incompatible.

Ordinary Tart writes checkpoints directly and can exit on a save failure.
The custom controller validates first, writes to a temporary file, and resumes
the paused guest if writing fails. A timed-out operation keeps its recovery
record; inspect `vm logs` and retry `vm suspend` to finish a completed save.
An interrupted ordinary-Tart restore also retains a hard link to the checkpoint
until the original guest boot is verified. An ambiguous failure blocks startup
instead of guessing whether to restore or boot fresh. Keep important work saved
to disk; memory checkpoints do not replace durable files or backups.

If a completed save outlived its command, `vm resume` verifies completion and
uses it directly. If the checkpoint is unusable, `vm suspend discard --yes` is
an explicit last resort **while Tart is stopped**: it removes saved memory and
its recovery record, keeping the guest disk. This loses unsaved work and processes;
the next `vm start` boots macOS normally and may require filesystem recovery.
Discard is never automatic and is not offered as a routine menu action.

Use `vm tmux` after resume to reattach to the preserved terminal. Saving guest
memory does not save the host's SSH/proxy processes or remote network peers, so
existing SSH connections are not promised to survive this explicit operation.
Ordinary host lid sleep is a different case; its physical verification remains
pending.

## Framework boundaries and other runtimes

Apple exposes runtime changes to an existing
[VirtioFS device's directory share](https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdevice).
CPU, memory allocation and sound devices remain part of the initial VM
configuration; volume is a guest setting. Lume also supports live directory
sharing in its [native viewer](https://cua.ai/docs/lume/guides/manage-vms).

[Apple's save/restore API](https://developer.apple.com/documentation/virtualization/vzvirtualmachine/restoremachinestatefrom(url:completionhandler:))
requires the same host and compatible configuration. Switching wrappers does not
remove those constraints. Tart already exposes suspend mode; Second Mac adds
lifecycle coordination, safe failure behavior for custom Tart, preserved launch
settings, backup exclusion, and menu integration. Ordinary in-memory pause in a
runtime does not release its process/RAM or survive quitting it.
