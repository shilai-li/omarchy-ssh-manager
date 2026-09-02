# AGENTS.md — omarchy-ssh-manager

Maintenance notes for anyone (agent or human) editing this repo. The plugin is
built and working; this file covers what is *not* obvious from the code.
User-facing docs — install, keys, findings, IPC — live in `README.md`. Don't
duplicate them here.

## What it is

**Omarchy SSH Manager** (`shilai_li.ssh-manager`) — a bar glyph that opens the
hosts in `~/.ssh/config`, tells you what ssh will actually do with each one,
and edits the file. QML running inside the already-running `omarchy-shell`
Quickshell process. One kind: `bar-widget`.

Non-negotiables:

- **The system ssh client is the authority.** `ssh -G` resolves the config,
  `ssh -o BatchMode=yes` tests authentication, `ssh-add -l` reports the agent.
  Nothing here parses a key, opens a socket, or reimplements any part of SSH.
  The one thing this repo's parser does that ssh cannot is attribution: which
  *file* and *line* a value came from, and which entry shadowed which.
- **No credential, ever.** Every ssh invocation carries `BatchMode=yes`,
  `PasswordAuthentication=no` and `KbdInteractiveAuthentication=no`, so the
  client fails where it would prompt. Never add an option that weakens host
  key checking (`StrictHostKeyChecking`, `UserKnownHostsFile`), never read a
  private key, never pass a password to anything.
- **The file is the user's.** An edit rewrites the lines it must and copies
  every other byte through. Comments, unmanaged keywords and ordering survive.
- **No network without a keystroke.** Opening the panel runs `scan.sh` and
  `ssh-add -l`; nothing touches the network until the user presses `t`.
- **Themed, never styled.** Zero hex literals, zero raw pixel sizes — only
  `Color.*` and `Style.*`.
- **Minimal is the feature.** No password storage, no SFTP, no SCP, no remote
  editing or monitoring, no embedded terminal. Ask before adding a surface.

## Layout

```
manifest.json      one kind, no settings
BarWidget.qml      owns the config text, the processes, the writes, IPC
Panel.qml          list + filter + key routing + the remove confirmation
Details.qml        one host in full (presentation only)
Editor.qml         the five-field form (presentation only)
SshConfig.js       pure: parse the include stream, edit one file's text
Diagnostics.js     pure: read ssh's answers, roll them into findings
bin/scan.sh        the config as ssh reads it, Includes expanded in place
bin/effective.sh   ssh -G, plus which identity files exist and their fingerprints
bin/probe.sh       TCP reachability and authentication, without a session
test/test.sh       everything, under plain node
```

The `.js` files stay **Qt- and locale-free** so the suite runs under `node`.
The `.sh` files are the only things that touch ssh or the filesystem. QML
paints and routes keys, and does neither.

## Ground truth — read it, don't guess

| What | Path |
|---|---|
| Shell source / UI kit / theme singletons | `/usr/share/omarchy/shell/{,Ui/,Commons/}` |
| Plugin contract + IPC table | `/usr/share/omarchy/shell/README.md` |
| Bar host (`bar.*` API) | `/usr/share/omarchy/shell/plugins/bar/Bar.qml` |
| Row/cursor idiom for lists | `shell/plugins/panels/bluetooth/Panel.qml` |
| Type-to-filter key handling | `shell/plugins/emojis/Emojis.qml`, `plugins/menu/Menu.qml` |
| A plugin shipping its own script | `shell/plugins/clipboard/capture.sh` |
| ssh's own rules | `ssh_config(5)` — first value wins, `Include` is in-place |

## Architecture invariants

**`ssh -G` decides, the parser attributes.** Anything of the form "what will
ssh use" must come from `effective.sh`. `SshConfig.effectiveFor` exists for the
questions `ssh -G` cannot answer — which file, which line, what lost — and its
answer is never shown as *the* value.

**Order is meaning.** `scan.sh` emits the config in ssh's reading order with an
`F` record per file, re-emitting `F` after an `Include` returns so the lines
below it are attributed to the right file. Without that, every keyword under an
Include is blamed on the included file, and every override report is wrong.
There is a test for exactly this.

**Everything is a positional argument.** Host names and paths reach the scripts
as `"$@"`, never spliced into a command string, and the scripts never `eval`.
A `Host` entry is user data; a config can name a file `$(rm -rf ~)`.

**Word splitting is not path splitting.** Include globs expand with `IFS`
empty, or a path with a space in it silently becomes two paths that do not
exist. Same reason `read -r` and `[ -f "$file" ]` are quoted everywhere.

**A block ends before the next block's comment.** The comment paragraph above a
`Host` line introduces *that* block. `blockEnd` backs up over it, which is what
makes add-then-remove a byte-for-byte round trip — the property the file
surgery is really judged on, and a test asserts it against a realistic file.

**New entries go above the first wildcard block.** ssh takes the first value it
obtains, so an entry appended after `Host *` loses every keyword that block
sets. `insertionIndex` is not a cosmetic choice.

**A FileView does not report its own writes.** `watchChanges` fires for
external edits only, so the rescan (and the `chmod 600`) hang off the `saved`
signal. Hanging them off `setText` returning would race the write.

**Unknown is a state.** An untested host is `–`, not `✓`. `parseProbe` sets
`tested` only when a record actually arrived, and every checklist row
distinguishes "we asked and it failed" from "we never asked".

**Shape carries status, not only color.** Themes may define `urgent` as any
color, and several map it to the same hue as the accent. The row marks
(`○ ● ◑ ✕`) and checklist glyphs (`– ✓ ! ✗`) are distinct without color; there
is a test asserting they stay distinct.

**The panel owns the cursor and nothing else.** Every host, probe and write
lives on `BarWidget.qml`; `Panel`, `Details` and `Editor` are read-outs that
call back into it. A bar surface exists per monitor, so anything the panel
owned would be state two monitors could disagree about.

**Keys are handled by hand, not by `PanelKeyCatcher`.** Typing filters the
list, and the catcher's `h j k l x` bindings would make half the alphabet
impossible to type. `Panel.handleKey` returns `false` for anything it does not
claim, which is how the editor's text fields keep working while the panel item
still has `Keys.priority: Keys.BeforeItem`.

## Style rules

| Do | Don't |
|---|---|
| `Color.foreground/.accent/.urgent/.popups.*` | any hex literal |
| `Style.space(12)`, `Style.font.caption…subtitle` | raw pixels, `pixelSize: 14` |
| `Style.cornerRadius` (may be `0`), `CursorSurface` | always-rounded, hand-rolled hover fills |
| `bar ? bar.foreground : Color.foreground` | assuming `bar` is set at construction |
| explicit `Keys.onTabPressed` handlers | `KeyNavigation`, which qmllint cannot check here |

Comment *why*, not *what*, in full sentences — match the shell's habit of a few
lines above a block explaining the trade-off.

## Dev workflow

```bash
cp -r . ~/.config/omarchy/plugins/shilai_li.ssh-manager   # no symlinks; validator rejects them
omarchy plugin validate ~/.config/omarchy/plugins/shilai_li.ssh-manager

QT_FORCE_STDERR_LOGGING=1 /usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell BarWidget.qml
/usr/lib/qt6/bin/qmlformat Panel.qml > /dev/null    # pure syntax gate

bash test/test.sh
omarchy-shell shilai_li.ssh-manager status          # JSON smoke test
```

**Back up `~/.ssh/config` before testing an edit path by hand**, and diff it
afterwards. `bash -c 'node -e ...'` against the real file is the cheapest way
to check a round trip without writing anything:

```bash
node -e 'const C=require("./SshConfig.js"),fs=require("fs");
const o=fs.readFileSync(process.env.HOME+"/.ssh/config","utf8");
const a=C.upsertHost(o,{Host:"tmp",HostName:"h",User:"",Port:"",IdentityFile:""},"");
console.log(C.removeHost(a.text,"tmp").text===o)'
```

Saving under `~/.config/omarchy/plugins/` hot-reloads QML. **Three things do
not hot-reload:** an already-bound `IpcHandler` target, an imported `.js` file
(the engine keeps the parsed copy), and anything cached from a previous plugin
version. All three need `omarchy-restart-shell`, so any change to `*.js`
requires a restart before it is what you are looking at.

**Reading qmllint output:** `qs.Commons` / `qs.Ui` can't resolve outside
Quickshell, so every file emits a cascade of `[import]`, `[unqualified]`,
`[unresolved-type]`, `[missing-property]`, `[required]`,
`[signal-handler-parameters]`, `[inheritance-cycle]`. That is noise — the
shipped built-ins emit the same. Compare *categories* against a built-in, not
counts; a category yours emits that theirs doesn't is worth chasing. That is
how `KeyNavigation` was found to be uncheckable here and replaced.

Shell-side errors go to the `omarchy-shell` journal — check there first when a
widget silently fails to appear.

## Rules for agents

1. Read the real file before writing. `ssh_config(5)` and the shell's own
   panels answer most "how should this behave".
2. No new dependencies. QML + Quickshell + the shell's singletons + OpenSSH.
3. Plugins run unsandboxed. The only file this plugin may write is
   `~/.ssh/config`, and only through `SshConfig.upsertHost`/`removeHost`. No
   network, no `sudo`, no writes anywhere else, ever.
4. Never weaken an ssh option to make a test pass. If a probe cannot answer
   safely, it reports `unknown`.
5. Before declaring done: `omarchy plugin validate` clean, qmllint categories
   match a built-in, `bash test/test.sh` green, add-edit-remove leaves a real
   `~/.ssh/config` byte-identical, the panel opens on a machine with no
   `~/.ssh/config` at all, and `t` on an unreachable host reports it without
   hanging the shell.
