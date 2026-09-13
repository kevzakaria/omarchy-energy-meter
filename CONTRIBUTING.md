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

Settings flow the same way, in one direction each. The widget **reads** current
values out of the `now` payload and **writes** them only by running
`omaenergy config key=value`, which validates, clamps and writes the config
file atomically.

Do not move `tariff`, `currency`, `baseline_w` or `psu_efficiency` into
`manifest.json`'s `barWidget.schema`. That store is `shell.json`, which the CLI
does not read, so the widget and the terminal would then disagree about what
your electricity costs — and the CLI is what actually computes the number. One
store, one writer, is the whole reason this is not a widget setting.

Money is rendered from `currency_symbol` and `cost_decimals` in the payload,
never from the `currency` code. Slicing the code is how `EUR` once rendered as
`0.42E`, and there is no prefix of `IDR` that means `Rp`.

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

- **open it against `release`, not `main`.** GitHub will offer `main`; retarget
  it. `main` is what every installed copy fast-forwards to on `omarchy plugin
  update`, so it moves only when a version is cut — see
  [Release](#release--marketplace)
- one logical change per PR
- an explanation of *why*, not only what
- which CPU/GPU the change was tested on, and desktop vs laptop
- README / CONTRIBUTING updates when behaviour changes
- **a Changelog entry in the README** under `Unreleased`, if the change is
  visible to a user: a new setting, a renamed JSON field, a number that moves.
  Say what moved and why, because someone will diff last month's kWh against
  this month's and deserve to know whether the machine changed or the maths did
- leave `preview.png` alone unless the UI actually changed
- any new image gets an explicit width in the README
  (`<img src="..." width="...">`). A bare `![](...)` renders at full container
  width, which turned a 1090x1240 panel screenshot into a wall

The marketplace listing is a screenshot of a specific commit. Unrelated
churn in `preview.png` is a visual lie about what that SHA draws.

## Release / marketplace

The listing on plugins.omarchy.org is bound to a specific **40-character
commit SHA**, not to `manifest.json`'s `version`. Bumping the version alone
does nothing.

### `main` is the release branch, because tags cannot be

The obvious instinct is to publish releases and let the marketplace serve a
tag. Omarchy's installer cannot do that. From its source:

```sh
# omarchy-plugin-add
git clone -- "$url" "$stage"                     # no --branch, no ref, no tag

# omarchy-plugin-update
git -C "$dir" fetch --quiet origin HEAD
git -C "$dir" merge --ff-only FETCH_HEAD
```

Both follow the repository's **default branch HEAD**. A tag or a GitHub Release
changes nothing about what a user receives, and the marketplace's pinned SHA
only governs what was *reviewed*, not what gets installed — the listing and the
installation are two different trust boundaries.

So the only real lever is what the default branch points at. Three tiers, each
with one job:

| Branch | Who writes to it | What it means |
| --- | --- | --- |
| `feature/*` | you | one change, rewrite freely |
| `release` | merged PRs | staged for the next version; the Changelog's `Unreleased` section accumulates here |
| `main` | a release merge only | **live**: every installed copy fast-forwards to it on `omarchy plugin update` |

PRs target `release`. Work piles up there until a version is worth cutting,
which is what makes the Changelog honest: by release time `Unreleased` already
lists everything that landed, written by whoever landed it, rather than being
reconstructed from a month of commit messages.

Cutting a version, on `release`:

```sh
# rename the Changelog's `Unreleased` heading to the version, bump
# manifest.json "version", commit
git switch main
git merge --ff-only release     # keeps main a linear prefix of release
git tag -a v1.2.0 -m 'v1.2.0'
git push origin main --follow-tags
```

Then publish the release notes, open the marketplace verification issue with the
new `main` SHA, and start a fresh `Unreleased` section on `release`.

### Release notes

Notes are a hand-written summary followed by GitHub's generated list. The
generated half is categorised by
[`.github/release.yml`](.github/release.yml), so **one label per PR** is what
makes it readable; `Maintenance` catches `*`, so an unlabelled PR is listed
rather than dropped. `Accuracy & correctness` is deliberately near the top:
in a tool whose job is to report a number, a change that moves that number
matters more to a reader than a new feature.

```sh
gh release create v1.2.0 \
  --target main \
  --title v1.2.0 \
  --generate-notes \
  --notes-start-tag v1.1.0 \
  --notes-file - <<'EOF'
## Highlights

### Added

- One sentence per user-visible change, with the PR link.

### Fixed

- What moved, and by how much. A number without a reference is not evidence:
  "GPU integration bias -2.03% -> -0.39% against a dense 100 ms trace" is
  useful, "improved GPU accuracy" is not.
EOF
```

`--notes-file -` supplies the Highlights; `--generate-notes` appends
`## What's Changed` and the full-changelog compare link beneath it. Check the
result and edit on GitHub if a category came out wrong, which usually means a
PR label was wrong.

Preview the generated half before tagging, so a bad label is caught then rather
than in public:

```sh
gh api -X POST repos/kevzakaria/omarchy-energy-meter/releases/generate-notes \
  -f tag_name=vNEXT -f target_commitish=release -q .body
```

For **v1.0.0** the generated half comes out nearly empty, because everything up
to it landed as direct commits rather than PRs — there is no PR history to
categorise. Drop `--notes-start-tag`, and let the Highlights carry the whole
story; the README's Changelog already has it in the right shape to lift from.
Releases after that get the categorised list for free, provided PRs are
labelled.

**Say plainly what the release does and does not do for a reader.** A GitHub
Release updates nobody: installs track `main`, so the tag is a human-readable
record, not a distribution channel. If a version needs an action — a
`systemctl --user restart omarchy-energy` because `interval_s` handling changed,
or `install.sh` re-run because the unit or udev rule changed — put that at the
top of the Highlights, because nothing else will tell the user.

**Never force-push or rebase `main`.** `omarchy-plugin-update` merges with
`--ff-only`, so a rewritten history is not a fast-forward from what users have
checked out: their update fails, the script resets them to `ORIG_HEAD`, and they
sit on an old commit until they remove and re-add the plugin. Rewrite
`feature/*` freely, keep `release` sane, treat `main` as append-only.

`--ff-only` in the release merge is our own hygiene rather than the user's: it
guarantees the SHA sent to the marketplace is exactly a commit that was
reviewed on `release`, with no merge commit invented at publish time.

**GitHub will offer `main` as the PR base**, because Omarchy requires `main` to
be the repository default. That cannot be changed without breaking installs, so
the guard is a PR template that says to retarget — check the base branch before
merging anything.

Bumping `version` in `manifest.json` is still worth doing — it is what the
marketplace and `omarchy plugin list` display — but it publishes nothing on its
own.

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

Pass `-s 2` as well, so the PNG is oversampled and stays crisp when the README
displays it at half its pixel width.

**`docs/dataflow.mmd` is one left-to-right chain on purpose.** The obvious
shape is two stacked lanes, each flowing across, but Mermaid ignores a
subgraph's own `direction` as soon as an edge crosses the subgraph boundary.
With the handoff edge, `flowchart TB` collapses all eight steps into a single
650x2036 column; drop the edge to get lanes back and you lose both the handoff
and the left-to-right ordering of the two phases, which are the only two things
the diagram exists to show. Do not "fix" it back to `TB` without checking the
rendered aspect ratio.

Also: keep `%%` comments free of backticks. Mermaid's tokenizer fails on them
with a misleading `Parse error on line 1`.
