# Keep an API key on the host

OpenRouter credentials can stay on your main Mac while Pi runs in the guest.
Pi installation offers this as an optional setup step; skipping leaves Pi's
normal provider setup available and the relay disabled. No extra package,
custom Tart build, VM restart or agent installation is required.

## Set up

For a key already saved in Pi's guest `auth.json`:

```sh
vm auth host --from-guest
```

This starts the guest if needed, moves its saved OpenRouter key to private host
storage, enables the relay, and replaces Pi's current key with a local relay
credential. It does not erase old snapshots, backups or separately saved copies
of that key. Rotate the key if you need those old copies to stop working.

For a new key:

```sh
vm auth set               # Hidden key entry; enable now and at future VM starts
vm pi
```

`vm auth set` never accepts a key as a command-line argument. It creates the
private host file and configures Pi when the relay starts. It does not boot a
stopped VM. To edit a file instead, use `vm auth host`, then `vm auth relay on`.

The default host file is `~/.local/share/agent-vm/credentials/openrouter.key`,
mode `600`, outside the guest disk and shared folders. `vm auth host --path`
prints its actual location, including any `AGENT_VM_HOME` override. Keep this
file private and outside folders you choose to share. Key changes take effect
on the next API request without restarting the relay or Pi.

On first installation, append `--agents pi` to the installer. It offers private
key entry, or asks before using an existing host key. **Press Return to skip**
and configure your preferred provider normally in Pi. With no terminal, this
optional step is also skipped. Skipping saves the relay as disabled, so adding
a host key for another VM later does not enable it. No key means no credential
server or tunnel; opt in later with `vm auth set`. Removing or emptying the key
file stops a running relay too. `--host-credentials none` skips the offer;
`--host-credentials openrouter` explicitly selects host setup and can reuse an
existing key without another question. Even that setup can be skipped if no
key is available. Retries retain the saved choice, including a skipped key.
Agents remain optional: the same relay can serve another compatible
client without Pi installed by selecting `--host-credentials openrouter`.
Existing installations are preserved. Installing Pi later with
`vm agents add pi` makes the same optional offer, or automatically connects it
to an already-enabled relay. Updating an already-installed Pi does not prompt
again or change the relay choice. Adding an agent never silently reverses a
previous relay opt-out.

```sh
vm auth relay status
vm auth relay off         # Revoke access now, without stopping the guest
vm auth guest             # Edit Pi's guest auth file explicitly
```

Plain `vm auth` edits the host key when the relay is enabled, otherwise Pi's
guest credentials. Turning the relay off removes its managed Pi URL and token;
it does not put the upstream key back into the guest. Changes made while the
guest is stopped are applied on its next start. Restart an already-open Pi once
after switching credential modes; subsequent stops, resumes and key rotations
keep the same client settings.

## How it works

A small host-local HTTP relay forwards `/v1/` requests to OpenRouter's fixed
HTTPS API, replacing the local credential with the host key. Request bodies,
model choices, provider options, tool calls, responses and streaming pass
through unchanged. It does not parse prompts, enforce model policies, track
spending, retry billed requests or log request/response bodies. Pi keeps its
existing ZDR/Exacto routing configuration. This is credential placement, not an
additional agent sandbox: while access is enabled, the guest can use the
OpenRouter API with that key's authority and credit limits.

The guest reaches the service through a loopback-only forward over Tart's
private SSH channel. No host or LAN HTTP port is exposed to its Ethernet
network. Explicitly enabled relay access also works with `vm network off`,
just like other explicit port forwards. Turn the relay off separately to revoke
it. The host's current internet/VPN connection carries the provider requests.

The service starts with its VM and stops on shutdown, crash or suspend. Its
internal tunnel reconnects after a guest reboot while Tart remains running.
The keepalives used for that tunnel do not change interactive SSH settings. Its
address and local credential survive routine stop/start, suspend/resume and
code updates; explicit revocation rotates the credential. A changed relay
implementation restarts only that service, which can interrupt an in-flight
response. No guest or Tart reboot is needed. Unchanged updates reuse it.
`vm access` reports the grant, key presence and autostart setting. SwiftBar's
**Services** menu offers hidden key entry, current-run start/stop, and separate
autostart controls for OpenRouter and Mac control. A stopped VM stays stopped
when changing these settings. Key entry opens a host terminal.

Pi's managed guest files are `~/.pi/agent/models.json` and `auth.json`. Other
clients can read the private `~/.config/second-mac/model-relay.json` for its
`base_url` and local `token`. That token is usable through this VM's active
forward, not as an OpenRouter key. The relay adds no documents or shell-wide
API-key variables to the guest.

## Host service startup

| Service | New main-VM default | Manual control |
|---|---|---|
| OpenRouter credential relay | Off unless host-key setup is accepted with a key; inactive without a key | `vm auth relay on\|off\|status` |
| Guest UI/permission requests | On when `--ui` is selected; opt out with `--no-guest-control-autostart` | `vm guest-control on\|off\|status` |
| Automatic consent approval | Off; separate from allowing explicit `mac-control` requests | `vm permissions auto on\|off` |

Enabled services start only while their own VM runs. Managed stops revoke them
before shutdown; guest shutdown or a Tart crash is detected by a local lifetime
check every half second. Starting these two services does not contact OpenRouter
or run OCR.
Each service has a small local HTTP listener and a private SSH tunnel; UI work
and upstream requests happen only on demand. The optional automatic consent
watcher is different: it polls the display and is not enabled by either default.

Both services have the same controls:

| Intent | OpenRouter | Mac control |
|---|---|---|
| Enable now and on future starts | `vm auth relay on` | `vm guest-control on` |
| Disable now and on future starts | `vm auth relay off` | `vm guest-control off` |
| Enable this run; keep autostart unchanged | `vm auth relay on --once` | `vm guest-control on --once` |
| Disable this run; keep autostart unchanged | `vm auth relay off --once` | `vm guest-control off --once` |
| Choose future startup behavior | `vm auth relay autostart on` / `off` | `vm guest-control autostart on` / `off` |
| Inspect settings and activity | `vm auth relay status` | `vm guest-control status` |

`--once` requires a running VM and leaves the saved autostart setting unchanged.
Autostart changes affect the next VM run and leave current access unchanged in
either direction. A current-run choice expires when Tart exits, including
suspend; a guest-only macOS reboot under the same Tart process retains it.
Autostart may be selected before supplying a key, but the credential server
cannot run until one is present. Startup checks the private local key file;
it does not make an API request to validate the key with OpenRouter.

Each server creates and owns its **dedicated private tunnel**. Starting or
stopping it opens or closes that tunnel. These tunnels are separate from the
ordinary forwards in `vm ports` and SwiftBar's Network menu. Removing an
ordinary forward does not alter either service. For example:

```sh
vm ports remove host 8080     # Remove a host service's manually added forward
vm ports remove guest 3000    # Remove a guest service's manually added forward
```

## Copies and other providers

Throwaways start with host credentials disabled, even when their source uses
them. Copied relay settings are removed on the copy's first managed start.
Access is an explicit, independent choice:

```sh
vm throwaway auth ID relay on
vm throwaway auth ID relay status
vm throwaway auth ID relay off
vm throwaway auth ID relay autostart on
vm throwaway guest-control ID on
vm throwaway guest-control ID status
vm throwaway guest-control ID off
vm throwaway guest-control ID autostart off
```

Each enabled VM has its own local credential and forward; revoking one does not
revoke another. Turning a stopped copy's grant on does not boot it; its service
starts on its next managed start and stops with that copy. Use
`--once` on either service's `on` or `off` command for the current VM run only.
The upstream host key is shared. Old throwaways retain their
saved implementation and are not automatically upgraded to gain this feature.
Guest-held credentials, if any, still copy with the disk as usual.
The host key is not part of `vm snapshot` or `vm backup`; protect it through
your host backup policy. Restoring a guest retains the current host grant and
reconciles its client settings at the next managed start.

Only OpenRouter is implemented. The same pattern is useful for search services,
private package registries and Git hosting APIs. For cloud files, running
rclone on the host and sharing a selected mounted directory may be simpler
than proxying its storage APIs.

Codex and Claude API-key gateways are possible future adapters. OpenAI also
documents [ChatGPT-plan OAuth with Codex app-server](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server),
which makes a host-held subscription adapter a plausible next step, with its
own registration, refresh and compatibility work. Claude documents
[gateway credentials and subscription behavior](https://code.claude.com/docs/en/llm-gateway).
Neither subscription route is implemented or tested here; subscription login
is not interchangeable with API billing. Existing Codex/Claude login behavior
is unchanged. The opt-in guest UI/permission service (`vm guest-control`) is a
separate service and grants no credential access.
