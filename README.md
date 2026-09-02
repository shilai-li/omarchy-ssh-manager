# Omarchy SSH Manager

The hosts in your `~/.ssh/config`, in the bar — with the answers to *why isn't
it connecting* next to each one. For [Omarchy](https://omarchy.org).

![SSH Manager host list](assets/ssh-manager-host-list.png)

```
SSH Manager                                    ssh-agent: 1 key
Search hosts…
──────────────────────────────────────────────────────────────
● omarchy                                              ~/.ssh/id_ed25519
  shilai_li@192.168.10.175
● server                                                    Authenticated
  user@10.0.0.20
✕ devbox                                                      Unreachable
  dev@example.com
──────────────────────────────────────────────────────────────
↑↓ move   enter connect   → details   ^t test   ^n new   type to filter
```

- **It runs the real ssh client.** `ssh -G` for the effective configuration,
  `ssh -o BatchMode=yes` for authentication, `ssh-add -l` for the agent.
  Nothing about SSH is reimplemented here.
- **It never handles a credential.** Every probe runs with `BatchMode=yes`,
  `PasswordAuthentication=no` and `KbdInteractiveAuthentication=no`: ssh fails
  where it would otherwise prompt. No password is read, stored, forwarded or
  cached — by design, not by policy.
- **Your file stays your file.** Edits rewrite the lines they must and copy
  every other line — comments included — through untouched.
- **No Electron.** QML running inside the `omarchy-shell` process you are
  already running.
- **Themed.** No hardcoded colors or sizes; it repaints itself when you run
  `omarchy theme set`.

---

## Install

```bash
omarchy plugin add https://github.com/shilai-li/omarchy-ssh-manager.git --enable
```

Or by hand, from a clone:

```bash
cp -r . ~/.config/omarchy/plugins/shilai_li.ssh-manager
omarchy-shell shell rescanPlugins
omarchy plugin enable shilai_li.ssh-manager
```

The widget lands on the right of the bar. Move it with `omarchy bar move`.

> Plugins run unsandboxed inside your shell. Read the code before you enable
> it — this one reads and writes `~/.ssh/config`, so that goes double.

## Uninstall

```bash
omarchy plugin remove shilai_li.ssh-manager
```

Nothing else to clean up: this plugin keeps no state of its own.

---

## The interface

### The list

Every `Host` entry ssh reads, including the ones in `Include`d files, in the
order ssh reads them. Wildcard entries (`Host *`) sort to the bottom and are
marked as patterns — they are not somewhere to connect, but they are usually
where a surprising value came from.

| Mark | |
|---|---|
| `○` | not tested yet |
| `●` | answered and authenticated |
| `◑` | answered, but refused the key |
| `✕` | unreachable |

Nothing is tested until you ask. Opening the panel makes no network
connection.

| Key | |
|---|---|
| `↑` `↓` | move |
| `enter` | connect in a terminal |
| `→` | details |
| `^t` | test the selected host |
| `^n` | new host |
| `^e` | edit the selected host |
| `delete` | remove the selected host (asks first) |
| anything else | filters the list |
| `esc` | clear the filter, then close |

**Left click** a row to connect, **right click** for details.

### Details

![SSH Manager host details and diagnostics](assets/ssh-manager-host-details.png)

```
omarchy

HostName       192.168.10.175
User           shilai_li
Port           22
IdentityAgent  ~/.bitwarden-ssh-agent.sock

IDENTITIES SSH WILL TRY
✓ Main Dev Key                                       in agent

Host reachable                                              ✓
SSH agent                                          1 key    ✓
Key available                              in the agent     ✓
Authentication                                              ✓
Config valid                                                ✓

defined in ~/.ssh/config:4
```

The values come from `ssh -G <host>`, so they are what ssh will actually use —
`Include`s, `Match` blocks and wildcards already resolved.

**Identities ssh will try** is the part `ssh -G` cannot tell you on its own: it
lists the six default key names whether or not they exist and says nothing
about the agent. This list is the keys that are really there, in the order ssh
will offer them, each marked `on disk`, `in agent`, or `missing`.

A dash in the checklist means *not asked*, never *fine*. `Host reachable` and
`Authentication` stay dashed until you press `t`.

| Key | |
|---|---|
| `c` / `enter` | connect |
| `t` | test this host |
| `e` | edit |
| `n` | new host |
| `x` | remove (asks first) |
| `esc` / `←` | back to the list |

### Adding and editing

Five fields — `Host`, `HostName`, `User`, `Port`, `IdentityFile` — because
those are the five this plugin claims to manage. Everything else in a block is
preserved exactly: `ProxyJump`, `ForwardAgent`, a keyword this plugin has
never heard of, and every comment inside and around the entry.

A new entry is written **above the first wildcard block**. ssh takes the first
value it obtains for each keyword, so an entry appended after `Host *` would
silently lose every keyword that block sets — the most common way a
hand-edited `ssh_config` stops doing what it looks like it does.

Writes are atomic, and the file is left at mode `0600`.

---

## What it can tell you

| Finding | Where it comes from |
|---|---|
| Missing `IdentityFile` | a path your config names that is not on disk |
| Duplicate `Host` entries | the same name declared in two places, with both files and line numbers |
| Overridden values | a keyword set in a file that lost to an earlier one — ssh takes the first, not the last |
| Unreachable host | a TCP connection to the effective `hostname:port` |
| Authentication failure | `ssh -o BatchMode=yes <host> true`, classified by ssh's own message |
| Which key ssh will use | `ssh -G` identity list, filtered by what exists, cross-referenced with `ssh-add -l` fingerprints |
| Broken config | `ssh -G` refusing to parse, quoting its own error |

A `Host *` block losing to a host that names itself is *not* reported: that is
ssh working as intended, and reporting it would bury the real conflicts.

A host behind a `ProxyJump` is not called unreachable — the jump host is what
reaches it, so the TCP check is skipped rather than failed.

---

## Command line

```bash
omarchy-shell shilai_li.ssh-manager toggle
omarchy-shell shilai_li.ssh-manager refresh
omarchy-shell shilai_li.ssh-manager connect <host>
omarchy-shell shilai_li.ssh-manager test <host>
omarchy-shell shilai_li.ssh-manager status    # JSON
```

A Hyprland bind:

```
bindd = SUPER CTRL, S, SSH manager, exec, omarchy-shell shilai_li.ssh-manager toggle
```

The three scripts in `bin/` are the whole backend and run fine on their own:

```bash
bin/scan.sh ~/.ssh/config      # the config as ssh reads it, includes expanded
bin/effective.sh myhost        # ssh -G, plus which identity files exist
bin/probe.sh myhost            # TCP reachability and authentication
```

Each takes an optional trailing config path (`-F`), which is how the test suite
points them at a fixture instead of your real `~/.ssh`.

---

## Deliberately not here

No password storage, no SFTP browser, no SCP GUI, no remote file editing, no
remote monitoring, no built-in terminal. Connecting hands the host to your
default terminal running the system `ssh`; everything after that is between you
and the host.

---

## Development

```bash
omarchy plugin validate .
QT_FORCE_STDERR_LOGGING=1 /usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell BarWidget.qml
bash test/test.sh
```

`SshConfig.js` (parsing and file surgery) and `Diagnostics.js` (reading ssh's
answers) are Qt-free so the suite runs under plain `node`. The shell scripts
are tested by running them against a throwaway `~/.ssh`; no test connects to a
host that exists.

See [AGENTS.md](AGENTS.md) for the plugin contract, architecture notes and
house style.

## License

MIT. See [LICENSE](LICENSE).
