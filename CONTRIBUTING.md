# Contributing

This is the working copy of an Omarchy **bar-widget** plugin. It runs
unsandboxed inside the long-lived `omarchy-shell` Quickshell process, plus a
separate Python sampler daemon. The notes below are the ones that actually
break a desktop or produce a wrong watt reading — not a generic GitHub
workflow.

This file is not called `AGENTS.md` or `CLAUDE.md`, and it is not at a path
the shell treats as agent instructions, on purpose. `omarchy plugin add`
copies the whole tree into `~/.config/omarchy/plugins/`, so a root agent file
would become ambient context for whoever installed the plugin. Do not add
one.

## Project shape

The repository root **is** the plugin root. The marketplace validator requires
a `manifest.json` at that root and exactly one plugin per repo. There are no
git symlinks anywhere in the tree (mode 120000); the validator rejects them.

| Path | What it is |
| --- | --- |
| `manifest.json` | Plugin id, kinds, entry points. Marketplace listing is **not** this file's `version`. |
| `Panel.qml` `Bucket.qml` `Sparkline.qml` | Quickshell UI. The widget never reads sysfs. |
| `bin/omaenergy` | Python 3 sampler + CLI. Standard library only. |
| `systemd/omarchy-energy.service` | systemd **user** unit for the sampler loop. |
| `udev/99-omarchy-energy-rapl.rules` | Read-only `energy_uj` for group `wheel`. |
| `install.sh` / `uninstall.sh` | Second, explicitly user-run install. Copies files; never symlinks. |
| `docs/architecture.mmd` `docs/dataflow.mmd` | Component and pipeline diagrams (PNG siblings for the README). |

Plugin id: `io.github.kevzakaria.energy-meter`. It is lowercase and
**permanent** — it cannot be renamed or reused.

Runtime state lives outside the plugin tree:

- CLI copy: `~/.local/bin/omaenergy`
- SQLite: `~/.local/share/omarchy-energy/`
- Config: `~/.config/omarchy-energy/config.json`
- User unit: `~/.config/systemd/user/omarchy-energy.service`

### Two trust boundaries

1. **`omarchy plugin add` copies files only.** It never runs install hooks,
   never runs plugin code, and never runs sudo. Plugins land disabled so the
   user can read them before enable. That is the Omarchy contract, not a
   limitation of this repo.
2. **Privileged setup is a second, user-run step.** `install.sh` copies the
   CLI into `~/.local/bin/`, the unit into the user systemd directory, and
   (the only root action) the udev rule into `/etc/udev/rules.d/`, then
   reloads powercap. The RAPL rule grants read-only `energy_uj` to `wheel`
   because upstream keeps those files root-only after CVE-2020-8694
   (PLATYPUS). It adds no privilege `wheel` did not already have.

Removing the plugin with `omarchy plugin remove` does not undo the daemon,
the unit, or the udev rule. That is `uninstall.sh`.

## Running a modified copy

Develop in the directory the shell actually loads:

```
~/.config/omarchy/plugins/io.github.kevzakaria.energy-meter/
```

That path is a git checkout. Point it at your fork and work there. Editing
any other clone does nothing until those files are what the shell is serving.

**Saving a file does not reload a mounted bar widget.** The shell logs
`Local plugin changed, reloading:` and the running instance keeps its old
code. `omarchy restart shell` is mandatory after every QML change. This
silently wasted real debugging time on this plugin; it is not a nicety.
omapager hits the same thing (`Variants` windows are not recreated on hot
reload). Count on a restart, then look at the new code.

After a restart, confirm there is still **one** Quickshell process. Starting
a second one races the IPC socket, dies, and writes a crash report that
Quickshell then refuses to retry ("crashed within 10 seconds of launching").
Never launch `quickshell -p …` by hand for this plugin.

**Never run `omarchy refresh shell`.** That command resets `~/.config/omarchy/shell.json`
to the shipped defaults. The restart you want is `omarchy restart shell`
(same as `omarchy-restart-shell`).

`omarchy-shell` is an IPC client. It does not start the shell.

## Backend vs frontend

The two halves meet at the CLI's JSON. The widget only ever consumes that
JSON; it never opens sysfs, SQLite, or the config file itself.

- **Adding a field is safe.** Old QML ignores it.
- **Renaming or removing a field is a breaking change.** Update `bin/omaenergy`
  and the QML in the same commit.

Work on them independently:

| Change | Restart |
| --- | --- |
| QML | `omarchy restart shell` |
| CLI query path (`now`, `day`, `status`, …) | none — run it in a terminal |
| Sampler loop inside the daemon | `systemctl --user restart omarchy-energy.service` |

The CLI is an ordinary Python file:

```sh
omaenergy now --json
omaenergy day
omaenergy status
omaenergy status --json
```

`now` / period queries and `status` do not need the shell. They do need the
installed CLI on `PATH` (`~/.local/bin/omaenergy`) and, for live samples, a
running user unit.

## Validating a change

From the plugin directory (repo root or the config checkout):

```sh
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" *.qml
python3 -m py_compile bin/omaenergy
```

`$OMARCHY_PATH` is `/usr/share/omarchy` on a normal install. `qmllint` must
see the shell import path or every `qs.*` import looks broken.

Runtime:

```sh
qs log -p "$OMARCHY_PATH/shell" --tail 100          # QML / shell
journalctl --user -u omarchy-energy -f              # sampler daemon
```

`omarchy plugin validate` is the same manifest check the marketplace runs.
It will not catch a QML runtime error or a RAPL path the daemon cannot read.

## Rules specific to this plugin

These exist because the opposite failed, or because the number on screen
would lie.

- **The database stores only measured microjoules plus tracked duration.**
  Estimates (`baseline_w`, `psu_efficiency`) and price (`tariff`) are applied
  at query time, so recalibration fixes all history. Never bake an estimate
  into a stored row.
- **Never present an estimated number with a label that implies measurement.**
  The plugin's whole value is that distinction. CPU package and GPU are
  hardware-measured; the rest of the machine and PSU loss are estimates.
- **Every QML `Text` that renders a value from outside the plugin must set
  `textFormat: Text.PlainText`.** Qt's AutoText will treat markup-looking
  strings as rich text, and rich text loads remote `<img src>` from inside
  the shell process.
- **Widget health is whether fresh samples are arriving, not a process exit
  code.** A command that cannot exec produces no exit code at all. A green
  "the Process finished" check is how you miss a missing CLI.
- **Write nerd-font glyphs as `\u` escapes, not literal private-use
  characters.** Editors, diffs, and terminals otherwise eat or substitute
  them, and the bar shows a missing-glyph box.
- **No new runtime dependencies.** The backend is Python 3 standard library
  only (`sqlite3`, `argparse`, `json`). The widget is Quickshell / QtQuick
  only. A new import is a product decision, not a convenience.

## Reporting a bug usefully

Almost every plausible bug in this project is hardware-dependent. Attach:

1. `omaenergy status --json` — discovered sensors, database location, sample
   counts.
2. `omaenergy now --json` — what the widget would have rendered right then.
3. CPU and GPU model.
4. Whether the machine is a laptop.

A screenshot of the bar without those four is usually not enough to act on.

## Hardware support contributions

The most valuable contribution is support for hardware we cannot test.

Sensor selection is deliberately conservative: when the tool cannot be
confident a source means what it thinks, it reports that rather than a
plausible number. A wrong watt is worse than a missing watt.

A new sensor path needs evidence, not only code:

- the sysfs paths and their contents on the machine that works
- the kernel doc or driver source that defines the semantics
- a measurement that shows the values move with known load (and stay still
  when they should)

The udev rule currently matches `intel-rapl:*`. That is the sysfs name for
RAPL energy counters on both Intel and AMD. A different subsystem needs its
own rule and a reason it is still read-only for `wheel`.

## Commits and PRs

There is no enforced commit convention in this ecosystem. Please still:

- one logical change per PR
- an explanation of *why*, not only what
- which CPU/GPU the change was tested on, and desktop vs laptop
- README / CONTRIBUTING updates when behaviour changes
- leave `preview.png` alone unless the UI actually changed

The marketplace listing is a screenshot of a specific commit. Unrelated
churn in `preview.png` is a visual lie about what that SHA draws.

## Release / marketplace

The listing on plugins.omarchy.org is bound to a specific **40-character
commit SHA**, not to `manifest.json`'s `version`. Bumping the version alone
does nothing.

To publish a newer commit, open a **Plugin verification** issue on
[omacom/omarchy-plugin-marketplace](https://github.com/omacom/omarchy-plugin-marketplace)
using the "Verify or update a listed plugin" form. Choose **Verify and
publish a newer upstream commit**. Fill in:

- plugin id: `io.github.kevzakaria.energy-meter`
- repo URL: `https://github.com/kevzakaria/omarchy-energy-meter`
- the full 40-character HEAD SHA

First-time listing uses the `submit-plugin.yml` issue form instead: category
`Hardware`, at most three tags (`bar`, `power-management`, `system`).

The plugin id is permanent. Do not rename it, and do not reuse it for a
different plugin.

Shipping a systemd unit and a udev rule means the automated Security
Baseline will mark the submission `review-required` for capabilities
`installer`, `privilege`, and `service-management`. That is expected and
listable. It **blocks** on:

- `NOPASSWD: ALL` or an unrestricted shell in sudoers
- broad `systemctl` / `kill` wildcards
- privileged process control from shared temp
  (`privileged-process-control-from-shared-temp`)

Do not add a sudoers file. Do not put PID files under `/tmp`. Do not
`curl | sh`. `install.sh` copies local files; it does not fetch anything.

## Diagrams

Committed sources, with PNGs next to them for the README:

| Source | Rendered |
| --- | --- |
| [`docs/architecture.mmd`](docs/architecture.mmd) | [`docs/architecture.png`](docs/architecture.png) |
| [`docs/dataflow.mmd`](docs/dataflow.mmd) | [`docs/dataflow.png`](docs/dataflow.png) |

Re-render after a structural change (dark theme, to match Omarchy):

```sh
npx --yes @mermaid-js/mermaid-cli \
  -i docs/architecture.mmd -o docs/architecture.png -t dark -b '#0d1117'
npx --yes @mermaid-js/mermaid-cli \
  -i docs/dataflow.mmd -o docs/dataflow.png -t dark -b '#0d1117'
```
