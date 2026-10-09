# Second Mac

tl;dr: A macOS VM aimed for _personal use_, for running software you don't trust (like AI agents) and controlling exactly what it can and cannot see.

## Motivation

I, like most people, have lots of private stuff on my computer. Accounts, notes, downloads and browsing history, secrets in plaintext, etc. This is fine, and good even, if I can consider my computer my own workspace, where I can do things with privacy and peace of mind. The problem with what software has come to, however, is that I cannot.

So much software connects to the internet these days, there is more and more telemetry in everything, and programs often compete for space on _my_ machine using _my_ resources and bandwidth for goals that are either opaque or explicitly against my interests. If a program uses _my_ CPU to verify whether I am "allowed" to run code living on my disk, or if it uses _my_ network to send my data to a server with no benefit to me, it is not the type of thing that deserves to exist in _my_ space. Sometimes, these things are necessary to keep around due to certain features or conveniences, but I do not consider them to be anything other than leeches and hostile guests that I am wary of and temporarily tolerating.

For a long time, I coped with this state of things by minimizing the untrusted programs I install (hence why I have very few electron applications outside of VS Code, Obsidian, and the Mullvad client, while the rest like Slack and Discord can stay inside the browser sandbox), setting up firewalls and hosts filters so the software I did need (like Adobe) could stay in its own lane as much as reasonably possible, and just using manual tricks to oversee everything I do. I have considered it barely sufficient for my purposes, up until AI agents became a thing.

AI Agents have a qualitatively different threat model even compared to the hostile software I described above. Not only does it connect to remote servers for not only metadata telemetry but instead direct processing of the _active content I am using it for_ by design, but unlike proprietary programs like Adobe Creative Cloud where I can at least trust software above a certain scale and legality not to go delete my home directory on a whim or reach into my browser history to scan for things, AI agents very much do do all of that. As a result, I consider it borderline unacceptable to allow an AI agent into my workspace where everything else lives.

Many other people cope with this by having agents run on VPS's or containers or the like. This is fine for a large class of tasks, and for most everything on Linux systems, but I have sometimes encountered friction specifically because I am using a mac. For example, what if I want to compile something specifically for macOS for use on my computer? Or for example, what if I want to accelerate something with my mac's Metal GPU, which neither a VPS nor Docker/Orbstack can access properly? Or for example, what if the subject in question is something with a GUI where I would have wanted to run it in my mac if not for not trusting it?

I think Apple's Virtualization.framework, which allows the creation of VMs that virtualize files, GPU resources, and the GUI with high performance, is a great answer to the above. I can have what is essentially a second mac living in my mac, where I send software I don't trust to be cordoned off without access to anything of value.

There are so many wrappers around Virtualization.framework already though! So why build my own codebase? I initially did not set out to do this either, but the result was that I genuinely could not find anything prebuilt that suited my needs without building a set of scripts around it. Most of the things with many stars had so much "automation", "scale", "fleet", "disposable", etc. They are not aimed at people trying to run AI agents on their own computer but rather enterprises and software testing and stuff! This may sound like it does not matter, but I really think it does:
- I want one second mac, not a set of "deployable images" or something. My reason is actually technical: I would love to have a different VM for each piece of software I don't trust, but the problem with that is that if you want to upgrade macOS in place and get the latest security patches, these approaches require massively duplicating space for different macOS images! So the most I could do if I wanted to stay up to date on security and not waste like 50GB of space per program is to have a single "second mac", move individual projects in and out of it as I work on them, and sometimes create temporary copies of it (`vm throwaway`).
- The enterprise-focused software really does not have convenient things for personal users. For example, convenient controls for directory sharing, or port forwarding between host and guest, or control of video and audio input and output, or considerations for laptop sleep and wake (on default configs that kills SSH connections!), or when the VM would work with a VPN on, or really any niceties that a personal user would want.

Therefore, I took [Tart](https://github.com/openai/tart) and [Softnet](https://github.com/openai/softnet) and built a relatively large set of scripts around them to create a VM setup that is best for what _I_ want it to do.

## What it actually does

- **Accessing the VM:** `vm ssh` and `vm gui` for headless SSH connections and GUI control, respectively. I wanted this as simple as possible. In addition, you can control everything via the menu bar, thanks to a [SwiftBar](https://github.com/swiftbar/SwiftBar) integration.
- **Isolation:** the VM can see WAN but not LAN. It cannot see what is running on the host machine, or its files, except for the directories you share with it. See [SHARING](SHARING.md) for details: what I like to do is to move a project to the shared folder when I'm working on it, and then move it somewhere else when I'm done, so the VM can only see the project it's working on. This does not need any extra space on macOS.
- **Privacy:** some sensible basic privacy settings are applied. For example, analytics are turned off for homebrew and npm and everything else installed in the default script; guest DNS defaults to Quad9 when not on VPN; Brave with ad blocking enabled and Brave web3 bloat disabled is used for the default Chromium-friendly browser; there are some privacy features, like you can turn on a local service that lets you use authenticated APIs that need API keys (currently implemented: OpenRouter) without letting the guest have access to the secrets. If there is an extra sketchy software, you can create a throwaway VM copy without duplicating space to run that, and then delete the thorwaway.
- **User-facing conveniences:** whenever I ran into friction using this tool, I made the scripts default to removing that. SSH connections can survive closing and reopening the laptop lid; the network backend automatically switches if you are on a VPN with a kill switch (otherwise if VPN is on you would get no network in the guest); you can suspend the VM and keep everything it was working on without shutting down; you can automatically approve macOS permissions like screen recording and full disk access in the guest with a script (`mac-control`, which is also convenient for controlling the guest gui and screenshotting and stuff in general); there are specific commands for what we allow in the audio in/out and video in (including integration with OBS virtual camera); binaries can be shared between host and guest with `vm projects setup ~/vmshare/example` for uv, pnpm, and npm projects so you can work in a single directory and not duplicate storage; and a lot of other stuff.
- **Updating the config:** just run `vm update`.
- See [GUIDE.md](GUIDE.md) and [FEATURES.md](FEATURES.md) for more.

## Installation

An Apple Silicon Mac with **macOS 26 or later** and an administrator account is
required. The default allocation is 4 CPUs, 8 GiB RAM and a 100 GB sparse disk;
leave at least 4 GiB RAM for the host. Run as your ordinary account:

```sh
curl -fsSL https://raw.githubusercontent.com/procrastinine/second_mac/main/bootstrap.sh | /bin/bash
```

This installs the base command-line tools and no coding agents. Missing Command
Line Tools and Homebrew are installed automatically. macOS 26 needs a one-time
[Setup Assistant step](INSTALL.md#first-boot-on-macos-26-and-27); macOS 27 can
create the guest account automatically. Review
[bootstrap.sh](bootstrap.sh) or use the [local-checkout instructions](INSTALL.md)
if you prefer. Options go at the end of the same command, for example:

```sh
curl -fsSL https://raw.githubusercontent.com/procrastinine/second_mac/main/bootstrap.sh | /bin/bash -s -- \
  --name work-mac --user developer --menubar --ui \
  --profiles web,science --agents pi
```

Then use `vm ssh`, `vm gui`, `vm stop` and `vm update`. Names, resources and shared
folders are configurable. Rerun the same installer to resume interrupted setup.
The optional custom build is compiled locally; no Apple Developer account is needed.

## Documentation

| Read | For |
| --- | --- |
| [Installation](INSTALL.md) | Dependencies, all setup choices, resuming and reusing local images |
| [Using Second Mac](GUIDE.md) | Commands, tools, agents, permissions, updates and backups |
| [Features beyond Tart](FEATURES.md) | The complete inventory of additions and their limits |
| [Sharing](SHARING.md) | Native folders, scoped symlinks, writeback and backups |
| [Capabilities and restarts](CAPABILITIES.md) | Regular/custom Tart, live changes and restart requirements |
| [Security](SECURITY.md) | What isolation, privacy settings and explicit grants mean |
| [Testing](TESTING.md) | Verification, development checks and remaining limits |
| [Comparison](COMPARISON.md) | Tart, Cua/Lume and persistent versus disposable use |

For development, run `./tests/run.sh`; see [Testing](TESTING.md) for dependencies
and the latest-upstream patch check. Physical lid-close SSH survival remains a
per-machine test. Private framework input APIs and future upstream changes still
require compatibility testing; successful installation is not proof of every
feature on every Mac.

## License

This project's scripts and configuration are [MIT licensed](LICENSE).
[Tart](https://github.com/openai/tart/blob/main/LICENSE),
[Softnet](https://github.com/openai/softnet/blob/main/LICENSE),
[macFUSE](https://github.com/macfuse/macfuse/blob/master/LICENSE.txt), macOS and
optional tools retain their own licenses; their binaries and OS images are not
redistributed here. VM disks, credentials and local state live outside the
repository. This is an independent project.
