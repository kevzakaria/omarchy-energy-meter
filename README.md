# Energy Meter

Live power draw on the Omarchy bar, and a panel that breaks your machine's
energy use and cost down by **day, week, month, and year**.

Most power widgets are wattmeters: they tell you what the machine is drawing
right now and forget it a second later. This one is an **energy meter**: it
integrates and keeps a permanent daily rollup, so you can answer "what did this
computer actually cost me last month?"

<p align="center">
  <img src="preview.png" alt="Energy Meter panel and bar widget" width="400">
</p>

It is built around one rule: **never present an estimate as a measurement.**
CPU and GPU draw are read from hardware. The rest of the machine cannot be, so
it is an explicit, calibratable constant. The UI always shows you what
fraction of the number is real.

---

## Why this exists

Most people have no way to find out what their computer costs to run. A smart
plug or an in-home energy display answers it instantly, but that means buying
hardware, and plenty of houses have neither. A utility meter in a cupboard
that reports once a month tells you about the whole house, not about this
machine.

Meanwhile the machine already knows. Modern CPUs and GPUs carry energy and
power counters the kernel exposes for free; they are simply never accumulated,
so the information evaporates every second. This plugin does the accumulating:
**no extra hardware, nothing to buy, and a permanent record from the day you
install it.**

What that gets you is the part that is genuinely hard to guess:

- **Consumption over time, not a snapshot.** What a week of your actual work
  costs, not what the machine draws in the instant you happen to look.
- **Which days were expensive, and why.** A day of compiling and a day of
  reading email differ by a factor of three, and the breakdown separates them
  from the days the machine was simply switched off.
- **A number you can put against a bill.** Not to the cent, but close enough
  to know whether this machine is a rounding error on your electricity bill or
  a real line item, and close enough to tell whether a change you made
  (undervolting, a power profile, leaving it on overnight) actually mattered.

It is not a replacement for a wall meter, and it does not pretend to be: the
CPU and GPU are measured, the rest of the machine is an estimate you can
[calibrate](#accuracy-and-how-to-calibrate-it-away), and every screen tells
you which is which. If you do own a smart plug, use it to calibrate this once
and the two agree closely from then on.

---

## Contents

- [Why this exists](#why-this-exists)
- [Install](#install)
- [What you get](#what-you-get)
- [What is measured and what is estimated](#what-is-measured-and-what-is-estimated)
- [How the numbers are calculated](#how-the-numbers-are-calculated)
- [Accuracy, and how to calibrate it away](#accuracy-and-how-to-calibrate-it-away)
- [CLI](#cli)
- [Settings](#settings)
- [Architecture](#architecture)
- [Hardware support](#hardware-support)
- [Correctness notes](#correctness-notes)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Contributing](#contributing)
- [Changelog](#changelog)

---

## Install

Two steps, because `omarchy plugin add` only copies files: it never runs
install hooks and never runs `sudo`. The bar widget is the first step; the
sampler that produces its data is the second.

```bash
# 1. the widget
omarchy plugin add https://github.com/kevzakaria/omarchy-energy-meter.git --enable

# 2. the sampler daemon (+ the one root step, explained below)
~/.config/omarchy/plugins/io.github.kevzakaria.energy-meter/install.sh

# 3. your electricity price: the default is a placeholder, not your tariff
omaenergy config tariff=0.42 currency=EUR
```

Step 3 is also the gear in the panel's top-right corner, and it is retroactive:
set it whenever you find your last bill, and every figure the meter has ever
recorded is repriced.

`install.sh` is idempotent, prints what it will do before doing it, and needs
root for exactly one thing: a udev rule. `--no-udev` only defers that root
step; it does not give you a working GPU-only meter. Without a readable RAPL
package zone the daemon refuses to start rather than recording rows with no
CPU energy, and the unit has `Restart=always`, so it keeps retrying.

<details>
<summary><b>Why the root step exists, and what the rule does</b></summary>

CPU energy comes from RAPL, at `/sys/class/powercap/*/energy_uj`. Upstream
Linux made that file root-only in response to
[CVE-2020-8694](https://nvd.nist.gov/vuln/detail/CVE-2020-8694) (PLATYPUS: RAPL
is a power side channel, and at high sample rates it can leak key material).

The rule grants **read** access to group `wheel` on RAPL **package** zones
only, and nothing else:

```
ACTION=="add", SUBSYSTEM=="powercap", KERNEL=="intel-rapl:*", ATTR{name}=="package-*", RUN+="/usr/bin/chgrp wheel /sys%p/energy_uj", RUN+="/usr/bin/chmod 0440 /sys%p/energy_uj"
```

What it changes is narrower than root, and wider than nothing. A member of
`wheel` can already read this counter by authenticating to `sudo`; the rule
removes that authentication step, so any process running as you reads the
package counter directly, at whatever rate it likes. That rate is the part
that matters for a side channel, which is why the scope below is worth
reading rather than skipping. It grants no write access and no new command.
The `ATTR{name}=="package-*"` match keeps it off the `core` sub-zone
(`intel-rapl:0:0`), which the daemon never reads and which is the
higher-resolution domain for PLATYPUS-class power side channels.
`uninstall.sh` removes the rule. If you would rather not grant it, `--no-udev`
only defers the root step: without a readable RAPL package zone the daemon
refuses to start rather than guessing the CPU term, and the unit's
`Restart=always` keeps retrying.

`wheel` is the admin group on Arch, which Omarchy is built on. On a
distribution that uses a different one, change the group in the rule before
installing it and add yourself to whichever group you pick. `install.sh` checks
afterwards whether the counter is actually readable by you, and if it is not it
names which of the three causes applies: the rule is missing, you are not in
the group, or the rule has not been applied yet.

</details>

Data starts accumulating at install time. RAPL counters are volatile and carry
no history, so **there is no way to recover consumption from before the daemon
first ran**. The sooner it is running, the sooner the monthly view means
something.

---

## What you get

**On the bar**: a bolt and the live figure. Right-click cycles what it shows:
live watts → today's kWh → this month's kWh. It goes to the theme's urgent
colour at or above a configurable threshold, and drops the number entirely if the
backend stops answering. It will never show you a stale reading styled as a
live one.

<p align="center">
  <img src="docs/bar.png" alt="The bar widget: a bolt and the live figure" width="620">
</p>

**In the panel**

| | |
|---|---|
| Hero | Current draw, with a CPU / GPU / rest stacked bar whose segments sum to the total within display rounding, and the share of the reading that is hardware-measured |
| Sparkline | Last 24 hours, hover for a crosshair readout |
| Breakdown | Day / week / month / year, each row with energy, cost, average while tracked, and largest sample |
| Coverage | Any bucket that was not fully sampled is marked, so a day the machine was off for 18 hours never reads as a low-consumption day |
| Settings | A gear in the top-right corner opens a config pane: price, currency, the estimate constants, and the sampling options, each with its units and what it does |

<p align="center">
  <img src="docs/settings.png" alt="The settings pane: price per kWh, a currency picker, a symbol override, and decimal places" width="380">
</p>

**Everything is configurable from the panel itself**: the gear in the panel's
top-right corner opens this. Price per kWh, currency, the two
estimate constants, and the sampling options, each with its units and a line
saying what it does. No config file to find, no terminal needed.

The settings are grouped by consequence rather than by type, because that is
the distinction that matters: the first group **re-prices every stored day the
moment you save it**, while the second only changes future sampling and says so.

The main view carries numbers and nothing else: no disclaimer paragraph, no
tariff line. The explanation of *why* the total is an estimate lives in the
settings pane, right next to the two constants that make it one, which is where
someone reading it can actually act on it. What stays on the front is the live
`76% measured` figure, because that is a measurement, not prose.

The pane is also reachable without the mouse, so you can bind it:

```bash
omarchy-shell io.github.kevzakaria.energy-meter settings
```

Inside the pane, `Enter` saves and `Escape` closes, from a field or from the
pane itself. A save confirms what it wrote: a price or a baseline shows the
figure it just moved, since those apply to the whole history and the point is
that you can watch the number change; a sampling key tells you it needs the
restart button instead.

---

## What is measured and what is estimated

This table is the most important thing in this README.

| Term | Source | Real? |
|---|---|---|
| **CPU / SoC** | RAPL `package-*` energy counter. On AMD this is MSR `C001_029B` (the whole socket: core complexes plus the I/O die) | **Measured.** A true accumulating energy counter, so its integral is exact at any sample rate |
| **GPU** | amdgpu hwmon `power1_average` (label `PPT`) | **Measured, integrated.** Not a counter: a firmware-filtered power estimate in whole watts, integrated by sampling. See [GPU sampling](#gpu-sampling-is-quadrature-not-counting) |
| **DRAM, NVMe, SATA, fans, chipset, USB** | `baseline_w` constant | **Estimated.** A typical desktop board exposes no sensor for any of it |
| **PSU conversion loss** | `psu_efficiency` constant | **Estimated.** Not observable from inside the machine at all |

RAPL's package domain does **not** include DIMMs, the discrete GPU, or the
chipset, so `baseline_w` fills a genuine gap rather than double counting the
IOD. (Verified against the kernel's `amd_energy` documentation and
`drivers/powercap/intel_rapl_msr.c`, and empirically: loading all 32 threads
moved the package figure from 41.6 W to 130.6 W while GPU PPT stayed flat.)

---

## How the numbers are calculated

### The one design decision that matters

**The database stores only measured microjoules and the duration they were
measured over.** `baseline_w`, `psu_efficiency` and `tariff` are applied at
*query* time, never written into a row.

That means recalibrating the baseline, correcting your PSU efficiency, or
fixing your electricity price **retroactively corrects your entire history**.
If the estimates were baked in at sample time, you would have to throw the
history away and start again. (This already paid for itself: a 1000× unit-bug
in the kWh conversion was fixed with no data loss, because the stored rows were
raw joules.)

<p align="center">
  <img src="docs/dataflow.png" alt="Measured microjoules are stored; estimates are applied only at query time" width="900">
</p>

### Per sample

The CPU term is a delta of an accumulating counter, taken modulo its wrap
range:

$$E_{\text{cpu}} = (C_{\text{now}} - C_{\text{prev}}) \bmod R \quad [\mu\text{J}]$$

where $R$ is `max_energy_range_uj`. The GPU term has no counter, so it is
integrated by the trapezoid rule over sub-samples taken every
`gpu_interval_s`:

$$E_{\text{gpu}} = \sum_{i} \frac{P_i + P_{i-1}}{2}\,\Delta t_i \times 10^{6} \quad [\mu\text{J}]$$

Both go into the row along with $\Delta t$. Nothing else does.

### At query time

Energy for any bucket, as it would appear at the wall socket:

$$E_{\text{socket}} = \frac{E_{\text{cpu}} + E_{\text{gpu}} + P_{\text{base}} \cdot t_{\text{tracked}} \times 10^{6}}{\eta_{\text{PSU}}} \quad [\mu\text{J}]$$

$$\text{kWh} = \frac{E_{\text{socket}}\,[\mu\text{J}]}{3.6 \times 10^{12}}
\qquad\text{since } 1\,\text{kWh} = 3.6\times10^{6}\,\text{J} = 3.6\times10^{12}\,\mu\text{J}$$

$$\text{cost} = \text{kWh} \times \text{tariff}$$

Every watt and kWh the tool reports is **at-socket**: each measured component
is divided by $\eta_{\text{PSU}}$ individually and the estimate is added in, so
the parts sum to the whole within display rounding (0.1 W, 0.0001 kWh). The
total and each component are rounded independently, so `cpu_w + gpu_w + rest_w`
can differ from `watts` by 0.1 W. The raw sensor-side values are still
available as `cpu_dc_w` and `gpu_dc_w` for calibration.

### Worked example, with real output

```console
$ omaenergy now
  now        164.8 W    at socket, mean over the last 10s
                        cpu 71.2 + gpu 57.6 + rest 36.0 (estimated)
                        78% of this reading is hardware-measured
  today      1.944 kWh  €0.58
  month      1.944 kWh  €0.58
  boot       1.944 kWh  (partial: not sampled for the whole boot)
```

Sensors read 63.4 W CPU and 51.3 W GPU on the DC side, with
`baseline_w = 32`, `psu_efficiency = 0.89`, `tariff = 0.30`:

| Step | Value |
|---|---|
| $71.2 \approx 63.4 / 0.89$ | CPU at socket |
| $57.6 \approx 51.3 / 0.89$ | GPU at socket |
| $36.0 \approx 32 / 0.89$ | estimated remainder at socket |
| $164.8$ | total, each term rounded to 0.1 W on its own (here $71.2 + 57.6 + 36.0 = 164.8$) |
| $0.782 \approx (63.4 + 51.3)/(63.4 + 51.3 + 32)$ | measured share, shown as 78% |

Each displayed watt is rounded independently to 0.1 W, so the printed parts
need not equal the printed total. In this snapshot they do; a tenth of a watt
of drift is still a rounding artifact, not a missing term.

And the same day as a bucket:

```console
$ omaenergy day
                   kWh   cost      avg      max
                               tracked  ~sample
  2026-09-13     1.944  €0.58     147W     245W  ██████████████████████  (13h tracked)
  total          1.944  €0.58
```

| Field | Meaning |
|---|---|
| `1.944 kWh` | $0.7531_{\text{cpu}} + 0.7152_{\text{gpu}} + 0.4754_{\text{rest}} = 1.9437$; displayed total is $1.9438$ (0.0001 kWh of independent rounding) |
| `147 W` avg tracked | $1.9438\,\text{kWh} \times 1000 / 13.222\,\text{h}$: the average **while sampling**, not across the calendar day |
| `245 W` max sample | the largest single-interval **average**. A spike shorter than `interval_s` is averaged away, which is why this is never called a peak |
| `13h tracked` | coverage $= 13.222 / 15.179 \approx 0.871$: the day is 87% sampled, so this row is a partial total and marked as one |

---

## Accuracy, and how to calibrate it away

Out of the box, expect the total to sit within roughly **±15-20% of a wall
meter**, dominated entirely by the two estimated constants.

What it gets *right* regardless is **trends and comparisons**: the part of the
draw that varies with what you are doing is the part that is genuinely
measured, so "this week was 40% heavier than last week" is trustworthy even
while the absolute figure carries a constant-offset uncertainty. At idle the
estimate is a large share of a small number; under load it is a small share of
a big one.

**With a wall meter (or a smart plug) you can remove most of that error in five
minutes:**

1. Let the machine idle. Read the metered watts, e.g. 105 W.
2. `omaenergy now --json` → take `cpu_dc_w` and `gpu_dc_w`, e.g. 41 and 15.
3. $P_{\text{base}} = (\text{metered} \times \eta) - (\text{cpu}_{dc} + \text{gpu}_{dc})$
   $= (105 \times 0.89) - 56 = 37.5$ W.
4. `omaenergy config baseline_w=37.5`. Your whole history is now corrected too.

If you know your PSU's efficiency curve, set `psu_efficiency` for your typical
load while you are there. 80+ Gold units sit near 0.90 at mid load and worse
when lightly loaded.

The default `baseline_w` follows your chassis type: **32 W** for a desktop
(four DIMM slots, several drives, case fans, chipset) and **12 W** for a laptop.
These are defensible starting points, not measurements of *your* machine.

---

## CLI

The widget is a thin client: it only ever renders JSON from this CLI, and never
touches sysfs itself.

```bash
omaenergy now                 # live draw, today, month to date, this boot
omaenergy day                 # last 14 days
omaenergy week -n 6           # last 6 ISO weeks
omaenergy month
omaenergy year -n 0           # every year on record (0 = all)
omaenergy chart --hours 24    # power over time
omaenergy status              # discovered sensors, database, configuration
omaenergy config              # show settings
omaenergy config tariff=0.42  # change the price per kWh, retroactively
omaenergy currencies          # codes it knows, with symbol and precision
```

Every subcommand except `daemon` takes `--json`. `status` is the one to paste into a bug report:
it reports which sensors were discovered and chosen, which were found and
deliberately not used, sample counts, and how many intervals were dropped.

---

## Settings

**Widget**: configurable from the bar's settings UI, stored in `shell.json`:

| Key | Default | |
|---|---|---|
| `refreshIntervalSec` | 5 | How often the bar polls the CLI. Does **not** change the sampling rate |
| `highWattThreshold` | 300 | Urgent colour at or above this many watts |
| `barLabelMode` | `watts` | `watts` / `todayKwh` / `monthKwh`. Right-click to cycle |

**Backend**: one source of truth, `~/.config/omarchy-energy/config.json`.
You never need to hand-edit it. Every key below is editable from the panel's
gear, and the same keys are settable from the terminal; both go through
`omaenergy config`, which validates and writes atomically. Out-of-range values
are rejected rather than clamped (only the daemon clamps intervals at startup):

```bash
omaenergy config                            # list everything, with what needs a restart
omaenergy config tariff=0.42                # your actual price per kWh
omaenergy config tariff=1444.7 currency=IDR # rupiah; PLN R-1/TR 1300 VA, not every golongan
omaenergy config baseline_w=37.5            # after calibrating
```

| Key | Default | |
|---|---|---|
| `tariff` | 0.30 | **Price per kWh. Set this first**: the shipped value is a placeholder, not your tariff. Retroactive |
| `currency` | `EUR` | ISO code, picked from a searchable list in the settings pane. Decides the symbol and the natural precision: `€0.42`, `Rp 2,041`, `¥180`. Any 2-5 letter code is accepted, listed or not. See `omaenergy currencies` |
| `currency_symbol` | auto | Override the symbol if your currency is not in the table, or you simply prefer another glyph |
| `cost_decimals` | auto | Decimal places for money. `2` where a cent exists, `0` for IDR / JPY / KRW / VND where it does not |
| `baseline_w` | 32 desktop / 12 laptop | The unmeasurable remainder. **Calibrate this.** Retroactive |
| `psu_efficiency` | 0.89 | AC→DC loss. Retroactive |
| `interval_s` | 10 | Database row interval. Needs a service restart |
| `gpu_interval_s` | 1.0 | GPU sub-sample rate: this is what sets GPU accuracy |
| `raw_retention_days` | 30 | How long per-sample rows are kept for charts. The daily rollup is kept forever |
| `sanity_max_cpu_w` | 1000 | Package draw above this is treated as a counter reset and dropped |
| `gpu_source` | `auto` | `auto`, `off`, or an explicit hwmon path |

`tariff` is the per-kWh price alone, the part of a bill that scales with what
you use. Where a bill splits into a fixed monthly charge and a per-unit price,
take the per-unit one: a German bill's `Arbeitspreis`, not the `Grundpreis`; a
PLN bill's per-kWh figure for your own `golongan` and connection size, not a
national number. The fixed part is deliberately out of scope, because it does
not change when this machine runs, and what this meter answers is what running
it costs you on top of standing still.

So there is no correct default to ship. In Germany alone, September 2026 sits
between roughly 24.9 ct/kWh on a new contract and 42.8 ct/kWh in
`Grundversorgung`, before regional network fees move it again
([strom-report](https://strom-report.com/strompreisentwicklung/)). Any figure
this project picked for you would be someone else's bill.

### Why price changes are retroactive

Everything in the first group (price, currency, baseline, PSU efficiency)
**applies to your entire history the moment you save it**, with no restart and
no data migration. That is not a convenience feature; it falls out of the
storage decision above. Cost was never written into a row, so correcting your
tariff simply re-derives every number the tool has ever reported.

Practically: you can run the meter for a month without knowing your exact
tariff, then enter it and immediately get a correct month. And when your
utility raises the price, you get to choose: set the new one and see the whole
history repriced, or keep the old one for comparison. Nothing is lost either
way.

The remaining keys only affect sampling, so they take effect on
`systemctl --user restart omarchy-energy`.

---

## Architecture

<p align="center">
  <img src="docs/architecture.png" alt="Kernel sysfs to sampler daemon to SQLite to CLI to bar widget" width="900">
</p>

| Path | |
|---|---|
| `~/.local/bin/omaenergy` | sampler daemon + CLI, one stdlib-only Python file |
| `~/.config/systemd/user/omarchy-energy.service` | the sampler, hardened and at idle priority |
| `~/.local/share/omarchy-energy/energy.db` | SQLite, WAL |
| `~/.config/omarchy-energy/config.json` | backend config |
| `/etc/udev/rules.d/99-omarchy-energy-rapl.rules` | the one root-owned file |

Two tables. `samples` is one row per interval of raw measured µJ, pruned after
`raw_retention_days`, and exists only to draw charts. `daily` is one row per
local day, cumulative, and **kept forever**: week, month and year are
aggregated from it, so a year of history is 365 rows.

Sampling costs two sysfs reads plus ten GPU reads and one SQLite write per
interval. Measured over 2 hours 13 minutes of real operation: **3.075 seconds
of CPU time** and about 11 MB RSS.

---

## Hardware support

Sensor selection is deliberately conservative. Where the tool cannot be
confident what a source means, it reports the source as unused rather than
integrating it into a plausible-looking number.

| Hardware | Status |
|---|---|
| AMD desktop CPU + discrete AMD GPU | **Verified.** The development machine (5950X + RX 7800 XT) |
| Any CPU exposing RAPL `package-*` | Supported. Multiple sockets are summed |
| AMD APU (integrated graphics) | CPU term only. The iGPU is already inside the RAPL package figure, and amdgpu's `power1_average` on an APU is documented to include the CPU, so counting it would nearly double the machine. The GPU term is dropped and the reason is reported in `status` |
| Ryzen 7000/9000 desktop with RDNA2 iGPU | **Unverified.** `cpu_has_integrated_gpu()` treats a CPU as an APU only if `radeon` appears in the `/proc/cpuinfo` `model name`, which those parts do not carry, so the double-count guard does not fire and an iGPU could be added on top of a package figure that already includes it. Workaround: `gpu_source=off` |
| Multiple AMD GPUs | The card with the highest `power1_cap` is chosen, never the lowest hwmon index: `hwmon10` sorts before `hwmon2`, so index order would happily measure a 15 W iGPU and ignore a 300 W card |
| NVIDIA / Intel GPU | Not read. The GPU term is recorded as 0 W rather than omitted; `omaenergy status` names the reason under `gpu_skipped` |
| Intel `psys` / `dram` zones | **Detected, not used.** `psys` would be strictly better than package-plus-estimate and `dram` would shrink the estimate, but neither could be verified on real hardware here. `omaenergy status` lists them as available and unused |
| No readable RAPL | The daemon refuses to start rather than record rows with no CPU energy |

Adding a path we cannot test is the single most valuable contribution to this
project. See [CONTRIBUTING.md](CONTRIBUTING.md#hardware-support-contributions)
for what evidence to include.

---

## Correctness notes

Five things this tool deliberately does not get wrong. Each was verified on
real hardware, and three of them came out of an audit that found them broken.

### The RAPL `core` zone is ignored

On Zen it is fed by
`MSR_AMD_CORE_ENERGY_STATUS`, which is per-core, and powercap reads it on the
package's lead CPU only, so the sysfs `core` file is *one physical core*.
Measured: pinning a busy loop to cpu0 raised it 6.6 W, pinning to cpu8 did not
move it at all, and with 32 threads loaded it read 5.8 W against a package
reading of 130.2 W. It is a subset of `package-0`, so adding them would double
count that core.

### Counter wraps are handled; resets are not guessed at

`energy_uj` wraps at
`max_energy_range_uj`, so deltas are taken modulo that range. A 10 s interval is
about 46× shorter than one wrap at this CPU's power limit, so a double wrap is
impossible. But a *reset* is arithmetically identical to a wrap and yields a
delta of nearly the whole range: about 6.5 kW over 10 s. Any interval implying
more than `sanity_max_cpu_w` of package draw is discarded as a reset, and any
interval longer than `max(4 × interval_s, 60 s)` is discarded as a suspend or
stall. Both are logged and both reduce `coverage` honestly instead of inventing
energy.

### GPU sampling is quadrature, not counting

The GPU term is a power estimate,
so its energy is only as good as the sample rate. Measured against a dense
100 ms reference trace on this hardware: a 10 s trapezoid was off by −2.0% at
idle and +2.6% under light load, while 1 s sub-sampling came in at **−0.39%**.
Hence `gpu_interval_s` defaults to 1 s while database rows stay at 10 s. The CPU
term needs none of this: it is a counter, so any spacing is exact.

### Partial buckets are labelled

`coverage` is the fraction of a bucket
actually sampled, and averages are explicitly "while tracked". A day the
machine was off for 18 hours reads `coverage: 0.25`, not "a cheap day". For a
month that is 3% sampled, the tracked average and the calendar average differ
by a factor of 30, so the two are never conflated.

### Nothing is labelled as more than it is

The live figure is a mean over the
last interval, not an instant. `max_sample_w` is the largest interval average,
not a peak. `uptime_kwh` says so when it does not span the whole boot. A
backend with nothing to report returns no numbers at all, rather than a zero
that would render as a measurement.

---

## Troubleshooting

**Bar shows no number, just a dimmed bolt**: the backend is not answering. The
widget judges health by whether fresh samples are *arriving*, not by exit
codes, because a command that cannot be executed produces no exit code at all.
Check:

```bash
systemctl --user status omarchy-energy
journalctl --user -u omarchy-energy -n 50
omaenergy now
```

**`no readable RAPL package zone`**: the udev rule is missing, or you are not
in `wheel`. Run `install.sh` again, or check `id` and
`ls -l /sys/class/powercap/intel-rapl:0/energy_uj` (it should be
`-r--r----- root wheel`).

**GPU reads 0 W**: expected on NVIDIA, Intel graphics, and AMD APUs.
`omaenergy status` prints the reason under `gpu_skipped`.

**Widget edits appear to do nothing**: saving a file reloads plugin *code* but
does not re-instantiate an already-mounted bar widget. Run
`omarchy restart shell`.

**Numbers look too high or too low**: you have not calibrated `baseline_w`.
See [above](#accuracy-and-how-to-calibrate-it-away). Check `measured_share`
in `omaenergy now --json`: the lower it is, the more of the figure is your
estimate rather than your hardware.

---

## Uninstall

```bash
~/.config/omarchy/plugins/io.github.kevzakaria.energy-meter/uninstall.sh
omarchy plugin remove io.github.kevzakaria.energy-meter
```

Run `uninstall.sh` first: `omarchy plugin remove` deletes the git checkout that
contains the script, so the other order cannot work.

`uninstall.sh` reverses the service, the udev rule, and the copied CLI at
`~/.local/bin/omaenergy`, but **keeps your database and config**, because the
database is history that cannot be regenerated. It prints both paths. Without
`--purge` both survive; `--purge` removes the config directory as well as the
database.

Deleting the udev rule does not restore permissions on an already-created
sysfs attribute; that grant persists until the device is recreated or the
machine reboots.

---

## Contributing

Contributions are genuinely welcome, and hardware support is the most useful
kind. This was written on one desktop, and almost every plausible bug in a
project like this is hardware-dependent.

**[CONTRIBUTING.md](CONTRIBUTING.md)** covers the development loop (including
the bar-widget reload trap that will otherwise cost you an hour), how to
validate a change, the JSON contract between the two halves, and what evidence
to bring when adding a sensor path.

Good first contributions:

- `psys` / `dram` support on Intel, with the evidence to back the semantics
- An NVIDIA GPU term via NVML
- A smart-plug source: a Shelly/Tasmota/Kasa reading is true wall power at
  under 1% error, and the storage and rollup layers are already source-agnostic
- Calibrated `baseline_w` figures for real machines, so the defaults improve

Bug reports: please include `omaenergy status --json` and
`omaenergy now --json`, your CPU and GPU model, and whether it is a laptop.

---

## Changelog

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

### Unreleased

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
  channels. An `ATTR{name}=="package-*"` match removes it. If you installed an
  earlier version, re-run `install.sh`; note that the old grant on an existing
  sysfs attribute persists until the device is recreated or you reboot.
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

### 1.1.0

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

### 1.0.0

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

---

## License

MIT. See [LICENSE](LICENSE).
