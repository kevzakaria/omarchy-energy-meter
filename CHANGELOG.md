# Changelog

`main` is what you get. Pull requests land on `release` and accumulate there
with their Changelog entries; `main` moves only when a version is cut.
`Unreleased` lives on `release` and is written as work lands rather than
reconstructed afterwards.

That split is forced rather than chosen. `omarchy plugin add` clones the
repository's default branch and `omarchy plugin update` fast-forwards to it, and
neither can be pointed at a tag, so a GitHub Release publishes nothing, and a
stable default branch is the only way to keep unreleased work out of your
install. `manifest.json`'s `version` is a display string with no effect of its
own. See [CONTRIBUTING → Release](CONTRIBUTING.md#release--marketplace).

## Unreleased

**Changed**

- The changelog lives here instead of inside the README. It was 252 of the
  README's 879 lines, so the file a first-time reader opens was nearly a third
  release history. The README now links here; `CONTRIBUTING.md` and the PR
  template point here too.

## 1.2.1

**Changed**

- `preview.png` is a landscape composite instead of a portrait screenshot of
  one view: the bar widget sitting among its real neighbours, the panel with
  the live draw and the 24 hour sparkline, and the settings pane. The
  marketplace card is a fixed 175 px box with `object-fit: cover`, so a
  near-square image was being cropped to whatever happened to be in the
  middle. At 1400x840 the card crops nothing.

## 1.2.0

Four independent audits went over this repo before it was shown to anyone.
None of them found a leak; all four found documentation that promised things
the code refuses to do, and a root-installed rule wider than its own
description. **Re-run `install.sh` to narrow the udev rule, then revoke the
old grant by hand** (the commands are under Security below): a new rule does
not re-apply to a device that already exists.

**Fixed**

- Uninstall instructions ran `omarchy plugin remove` first, which deletes the
  git checkout that contains `uninstall.sh`. The order is reversed, the copied
  CLI is named, `--purge` is described as removing config as well as the
  database, and deleting the udev rule is described as not restoring sysfs
  permissions until the device is recreated or the machine reboots.
- `--no-udev` was documented as leaving a GPU-only meter running. Without a
  readable RAPL package zone the daemon refuses to start, and `Restart=always`
  retries, so that flag only defers the root step.
- The live split and the worked example claimed the parts sum exactly. Each
  component is rounded independently (0.1 W, 0.0001 kWh), so the identity
  holds only within display rounding.
- The query-time formula added watts times seconds (joules) to microjoules.
  The rest term is now multiplied by $10^{6}$ so every addend is µJ.
- `omaenergy config` was described as clamping out-of-range values. It
  rejects them and leaves the file untouched; only the daemon clamps
  intervals at startup.
- NVIDIA / Intel GPUs were documented as "unavailable". The GPU term is
  recorded as 0 W; `omaenergy status` names the reason under `gpu_skipped`.
- The sampler CPU-time claim (2.0 s over 9.5 h) could not be reproduced on
  the live service, which now does ten GPU reads per interval. Replaced with
  a measurement from this machine.
- The GPU-sampling link pointed at bold paragraph text that generates no
  heading anchor.
- The bar's urgent colour is at or above `highWattThreshold`, not strictly
  above it.
- `--json` is not accepted by `daemon`.
- The settings screenshot alt text promised the estimate constants; the crop
  stops after Decimals.
- Changelog copy pointed at an `Unreleased` section "below" as if it lived
  on `main`; that section lives on `release`.

**Changed**

- Hardware support now names the unverified Ryzen 7000/9000 desktop + RDNA2
  iGPU case: the APU guard keys off `radeon` in the CPU model string, which
  those parts do not carry. `gpu_source=off` is the workaround.

**Security**

- **The udev rule now matches package zones only.** `KERNEL=="intel-rapl:*"`
  also matched the `core` sub-zone, so installing the rule granted `wheel`
  read access to the per-core domain as well: the one the daemon deliberately
  never reads, and the higher-resolution one for PLATYPUS-class power side
  channels. An `ATTR{name}=="package-*"` match removes it.

  **If you installed an earlier version, re-running `install.sh` is not
  enough.** A new rule does not re-apply to a device that already exists, so
  the sub-zone keeps the old grant until you reboot. Take it back now with:

  ```bash
  sudo chgrp root /sys/class/powercap/intel-rapl:0:0/energy_uj
  sudo chmod 0400 /sys/class/powercap/intel-rapl:0:0/energy_uj
  ```

  Check the result with `stat -L -c '%a %U:%G %n'
  /sys/class/powercap/*/energy_uj`: the `package-0` zone should read
  `440 root:wheel` and the `core` zone `400 root:root`.
- The claim that the rule "confers no privilege `wheel` did not already have"
  was too comfortable, and appeared in three places. It grants no write access
  and no new command, but it does remove the `sudo` authentication step, so
  any process running as you can then read the package counter at an
  unbounded rate. The rate is the part a side channel cares about.
- History and settings are no longer world-readable. The state and config
  directories are created `0700`, the database, its `-wal`/`-shm` sidecars and
  `config.json` `0600`, and the unit runs with `UMask=0077`. Existing files are
  tightened in place on start. A timestamped energy history reveals when the
  machine is in use, which is not something to leave at `0644`.

**Changed (backend)**

- Re-running `install.sh` now restarts the sampler when the CLI or the unit
  actually changed, and says so when nothing did. It used to copy a new CLI
  and leave the old process running, because `enable --now` is a no-op on an
  active unit, while the output implied the update had landed.
- `uninstall.sh --purge` removes the config directory as well as the database,
  and names both when you do not pass `--purge`. `config.json` used to survive
  a purge silently.
- `omaenergy config` no longer prints Python literals: an unset
  `cost_decimals` reads `auto`, and every value it displays can be pasted
  straight back. A bad number reads `must be a number` instead of
  `could not convert string to float`.
- `.gitignore` covers `.env*`, logs, and the other SQLite suffixes.

## 1.1.0

Saving in the settings pane used to be invisible: it worked, and looked
exactly like it had not. **Run `omarchy restart shell` after updating**, or the
already-mounted widget keeps running the old code.

**Added**

- Saving in the settings pane now confirms itself, and says what changed. A
  price or baseline reports the figure it just moved (`today now reads 1.74
  kWh / €0.52`, at the shipped `0.30`), because a retroactive setting is only
  believable if you can watch the number move; a sampling key says it needs
  the restart instead. Clicking Save with nothing edited says so rather than
  doing nothing.
- Enter saves while the settings pane is open. It already saved from inside a
  field; with no field focused the key did nothing, so the pane could not be
  driven without a pointer at all.

**Fixed**

- A successful save produced no visible change whatsoever. Only the failure
  path had a message, and because the pane covers the panel body, the
  recomputed cost was hidden behind it: a save that worked looked exactly like
  a dead button.
- `install.sh` blamed the wrong thing when the RAPL counter came out
  unreadable. It said the udev rule was missing even when the rule was already
  installed and the real cause was group membership. It now distinguishes the
  three causes, missing rule, user not in the group, and rule not yet applied,
  and prints the one command that fixes the case you are actually in.

**Documentation**

- Says which number off a bill `tariff` actually is: the per-unit price, a
  German bill's `Arbeitspreis` and not its `Grundpreis`, a PLN bill's figure
  for your own golongan and not a national one. It said the default was a
  placeholder without saying what to replace it with, and the fixed monthly
  charge being out of scope was never stated at all.
- Says that `wheel` is Arch's admin group and what to change on a distribution
  that uses another one. The rule always named `wheel`; nothing said why, or
  what to do if that is wrong for your system.

## 1.0.0

First release. The list below is longer than a first release usually warrants
because most of it is corrections found by auditing the thing before anyone
relied on it.

**Added**

- **A settings pane behind a gear** in the panel's top-right corner. Every
  backend key is editable there, grouped by consequence: the ones that reprice
  your whole history versus the ones that need a daemon restart, with the
  restart command offered as a button when it is actually needed.
- `omaenergy config`: the validated, atomic write path behind that pane, and
  the same thing from a terminal, so the price per kWh no longer means
  hand-editing JSON. `tariff`, `currency`, `baseline_w` and `psu_efficiency`
  apply to the **whole history** the moment they are saved.
- `omarchy-shell io.github.kevzakaria.energy-meter settings` opens that pane
  over IPC, so it can be bound to a key.
- Currency handling worth the name: a symbol and natural-precision table, so
  `EUR` renders `€0.42` and `IDR` renders `Rp 2,041` rather than `0.42E`.
  Overridable with `currency_symbol` and `cost_decimals`.
- `omaenergy currencies` lists the known codes with their symbol and precision.
  The settings pane's currency field is a searchable dropdown populated from
  it, showing each option's consequence (`EUR · € · €1,234.00`), so there is no
  second copy of the table in the QML. The list is not a cage: any 2-5 letter
  code can be entered, and a code that is already saved but unlisted stays
  selected instead of snapping to the first row.
- A "Why this exists" section, because the point is easy to miss: this is for
  people without a smart plug or a whole-home energy monitor. The counters are
  already in the machine and are simply never accumulated.
- `measured_share` in the payload and in the panel: the share of the reading
  that is hardware-measured rather than the baseline estimate. The plugin's
  central claim was previously invisible in its own UI.
- GPU sub-sampling at `gpu_interval_s` (default 1 s), independent of the
  database row interval.
- `uptime_truncated`, and a `status` report of sensors found but deliberately
  unused (Intel `psys` / `dram`).

**Changed**

- The main panel view is numbers only. The accuracy paragraph and the tariff
  line moved into the settings pane, beside `baseline_w` and `psu_efficiency`:
  the two constants that are the reason the total is an estimate. A caveat sat
  next to a dashboard is read once and then becomes furniture; sat next to the
  fields that fix it, it is a call to action. The live `measured_share` figure
  stays on the front, because it is a measurement rather than prose.

**Fixed**: most of these came out of two independent audits run before any
release, and they are listed because they explain why numbers moved

- **Mixed units in the live split.** The total and the estimated remainder were
  at-socket while CPU and GPU were raw DC sensor watts, so the panel's stacked
  bar did not add up to the number above it: a measured 14.2 W discrepancy.
  Everything is at-socket now and the parts sum exactly.
- **The daemon kept recording after losing RAPL.** A re-probe that found no
  zones returned a zero delta, so rows were written with no CPU energy while
  tracked time kept advancing: buckets looked complete but were missing the
  largest measured term. It now refuses to record instead.
- **Absence of data rendered as zero.** A `no_data` reply still carried
  `watts: 0`, which the widget presented as a measurement of 0 W. Degraded
  replies now carry no live numbers at all.
- **GPU energy bias.** A 10 s trapezoid measured −2.03% at idle and +2.6% under
  light load against a dense 100 ms reference. 1 s sub-sampling brings it to
  **−0.39%**.
- **A counter reset became a 6.5 kW phantom sample.** A reset is arithmetically
  identical to a wrap; implausible package draw is now discarded, as are
  suspend-length gaps, and both reduce `coverage` honestly.
- **Portability, the worst of them.** On an AMD APU the integrated GPU would
  have been counted twice, since it is already inside the RAPL package figure
  and amdgpu's own reading on an APU includes the CPU. GPU selection also
  picked the lowest hwmon index, which sorts `hwmon10` before `hwmon2` and
  would happily measure a 15 W iGPU while ignoring a 300 W card. Selection is
  now by power cap, and the APU case is dropped with the reason reported.
- **Names that overstated the number.** `peak_w` → `max_sample_w` (it is the
  largest interval *average*), `avg_w` → `avg_w_tracked` (averaged over the
  time sampled, not the calendar bucket), and the hero now says it is a mean
  over the last interval rather than an instant.
- **The kWh constant was wrong by 1000×** (`3.6e15` instead of `3.6e12` µJ per
  kWh). Because only raw joules are stored, fixing it corrected all existing
  history with no data loss.
- **The widget froze instead of degrading.** Health was judged from process
  exit codes, but a command that cannot be executed produces none, so a dead
  backend left the last good reading on the bar looking live. Health is now a
  freshness deadline, which also covers hung polls and a stopped daemon.
- Bucket spans are built with per-instant UTC offsets, so a DST transition day
  is 23 or 25 hours long and does not read as partially tracked.
- `omaenergy <anything> | head` printed a `BrokenPipeError` traceback at
  interpreter shutdown. Closing a pipe early is ordinary shell usage, not a
  crash, and it should not look like one.
