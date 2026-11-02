# Open-source study ledger

Mole CLI (Linux) learns rules and facts from other Linux tools, never their code; GPL and unlicensed sources contribute paths and facts only, and data taken from MIT sources is credited in `THIRD-PARTY-NOTICES.md`. Each row records which repository and commit was read, what Mole took, what it refused and why. Study clones live in the ignored `.artifacts/oss-linux/` (shallow); the full study notes, including file and line citations, are in the ignored `.artifacts/linux/` (`oss-research-linux.md` and `research-0.2.0/`). To refresh a row, `git -C .artifacts/oss-linux/<dir> pull --depth 1`, read the commits since the recorded one, and update the row in the same change.

## Baseline

| Dir | Repository | Studied | Commit | License | Area | Verdict |
|---|---|---|---|---|---|---|
| `bleachbit` | bleachbit/bleachbit | 2026-11-01 | `c23ee6d` | GPL-3.0 | clean | Followed for paths and running-owner guards |
| `kudu` | AdventDevInc/kudu | 2026-11-01 | `942af64` | MIT | clean | Reference for rule fields and safety notes |
| `Stacer` | oguzhaninan/Stacer | 2026-11-01 | `a44d056` | GPL-3.0 | clean, uninstall | Counterexample; unmaintained since 2024 |
| `flatsweep` | giantpinkrobots/flatsweep | 2026-11-01 | `7397d1b` | MPL-2.0 | uninstall | Followed for the Flatpak leftover test |
| `gdu` | dundee/gdu | 2026-11-01 | `b723b70` | MIT | analyze | Followed for mountinfo and trashinfo |
| `dust` | bootandy/dust | 2026-11-01 | `b6c6d8d` | Apache-2.0 | analyze | Reference |
| `disktree` | tobi/disktree | 2026-11-01 | `9b18b27` | MIT | analyze | Followed for volume, snapshot and removal guards |
| `czkawka` | qarmin/czkawka | 2026-11-01 | `d776b0a` | mixed | analyze | Reference |
| `rmlint` | sahib/rmlint | 2026-11-01 | `3a44e63` | GPL-3.0 | analyze | Reference |
| `npkill` | voidcosmos/npkill | 2026-11-01 | `56cbc39` | MIT | purge | Reference for target names (0.3.0) |
| `kondo` | tbillington/kondo | 2026-11-01 | `1d351ca` | MIT | purge | Target-to-project-file pairing (0.3.0) |
| `btop` | aristocratos/btop | 2026-11-01 | `fd1d292` | Apache-2.0 | status | Followed for sysfs discovery |
| `TLP` | linrunner/TLP | 2026-11-01 | `40b02a6` | GPL-2.0 | optimize | Defines what Mole never touches |
| `auto-cpufreq` | AdnanHodzic/auto-cpufreq | 2026-11-01 | `fe7b13b` | GPL-3.0 | optimize | Counterexample (stops other daemons); detection only |
| `omarchy` | basecamp/omarchy | 2026-11-01 | `5df8f9e` | MIT | first target | Target, not a source |
| `xdg-ninja` | b3nj5m1n/xdg-ninja | 2026-11-02 | `ebf481a` | MIT | uninstall | Data taken, hand reviewed (0.2.0) |
| `antidot` | doron-cohen/antidot | 2026-11-02 | `1dd77c7` | MIT template, unfilled | uninstall | Cross-check only; license template never filled in |
| `pacutils` | andrewgregory/pacutils | 2026-11-02 | `d3998fe` | MIT-style | optimize | Approach for `.pacnew` and unowned-file reports |
| `rebuild-detector` | maximbaz/rebuild-detector | 2026-11-02 | `2c8a754` | ISC | optimize | Approach only, no `ldd` |
| `lostfiles` | graysky2/lostfiles | 2026-11-02 | `fc988d5` | MIT | optimize | Exclusions used as negative test fixtures |
| `cleansys` | sorinirimies/cleansys | 2026-11-02 | `deb8558` | MIT | clean | Cache paths taken (0.2.0) |
| `Spruce` | shonubot/Spruce | 2026-11-02 | `8ea8e78` | GPL-3.0-or-later | clean | WebKitGTK and Snap cache paths |
| `Cleanr` | drl990114/Cleanr | 2026-11-02 | `6fa2cca` | MIT | clean | sccache path; its JetBrains model confirms ours |
| `cylon` | gavinlyonsrepo/cylon | 2026-11-02 | `cb339cf` | GPL | optimize | `.pacnew` and broken-link report ideas |
| `sweeper` | KDE/sweeper | 2026-11-02 | `963af37` | LGPL-2.1-or-later | clean | Out of scope (privacy, not disk) |
| `dua-cli` | Byron/dua-cli | 2026-11-02 | `bc03fed` | MIT | analyze | Nothing taken; its `st_dev` rule breaks btrfs |
| `mission-center` | mission-center-devs/mission-center (GitLab) | 2026-11-02 | `7a86367` | GPL-3.0 | status | App grouping and per-process GPU memory as ideas |
| `ubuntu-cleaner` | gerardpuig/ubuntu-cleaner | 2026-11-02 | `fc90eb2` | GPL-3.0 | clean, optimize | What its janitor plugins cover on Ubuntu; the removals themselves refused |
| `community/` | ten community Linux ports of Mole | 2026-11-01 | one shallow commit each | mixed | all | See below |

## Taken, by command

- **clean.** A rule per cache with the program that owns it, skipped while it runs (BleachBit). An allowlist of known caches; unknown folders under `~/.cache` are listed, never selected (BleachBit sweeps everything outside a keep list; Mole does the opposite). Per-app Flatpak caches `~/.var/app/<id>/cache` asked through `flatpak ps` (BleachBit, `6281eff5`). 0.2.0 cache rules: Steam shader caches, Heroic, Lutris shaders and installers, Wine installers (cleansys); WebKitGTK and Snap app caches (Spruce); Thunderbird `cache2` and Telegram (cleansys); sccache (Cleanr) (`87a59a5c`).
- **uninstall.** Flatpak data is a leftover only when no installation lists the app (flatsweep, with Trash instead of `rmtree`). Package names validated before they reach argv, removal previewed by the manager itself (`pacman -Rsp`) (`cea84ac2`). 74 home paths from xdg-ninja's catalog, each reviewed by hand, credential stores and shared paths removed (`f4dd4760`, `0d1f70fd`).
- **optimize.** Report-only checks for pending `.pacnew`/`.pacsave`/`.pacorig` under `/etc` and files no package owns (pacutils `pacreport`), foreign packages that need a rebuild, read with `readelf -d` rather than `ldd` (rebuild-detector), broken links in the home folder (cylon), with lostfiles' exclusions as fixtures of "unowned but legitimate" (`03052016`). Power managers are detected and reported, never changed (TLP, auto-cpufreq).
- **analyze.** Volumes from `/proc/self/mountinfo` (gdu); device-backed filesystems only, mount points refused, snapshots counted but not scanned (disktree); same filesystem decided by mount source and type, since every btrfs subvolume has its own `st_dev` (the reason dua-cli's rule was not taken).
- **status.** Battery, temperature and GPU sources from sysfs (btop); apps grouped by their systemd cgroup and per-process GPU memory from DRM fdinfo (mission-center ideas, `5331fcdb`); btrfs allocation from `/sys/fs/btrfs` without root.
- **purge.** kondo's model of pairing each build folder with the project file of the tool that made it, applied to every target; extra Linux targets from kondo (`_build`, `.stack-work`, `cmake-build-*`); Mole CLI (macOS)'s authored-content probe, node_modules install-record rule and 7-day activity (0.3.0).
- **Debian and Ubuntu.** The list of what an Ubuntu cleaner looks at (ubuntu-cleaner's plugins: apt cache, autoremovable packages, `rc` configurations, old kernels, thumbnails), each turned into the distribution's own bounded command or a report: `apt-get autoclean`, `apt-get -s autoremove` and `rc` packages reported, Snap revisions reported (0.4.0).
- **Trash.** `.trashinfo` reserved with `O_EXCL` before the move and rolled back on failure, per-volume `.Trash-$uid`, cross-device moves refused (gdu, disktree, and one community port's sink).

## Refused, and why

- Deleting `/var/cache/apt/archives` files as root, removing old kernels and running autoremove from a list (ubuntu-cleaner): root `rm`, kernel removal and `autoremove` are out of scope; apt's own `autoclean` and reports cover them.

- Emptying archived journals by size (`journalctl --vacuum-size=1`, BleachBit; `--vacuum-size=100M`, cylon): Mole vacuums by time with a floor.
- `paccache -rk0`, `pacman -Scc`/`-Sc`, `--noconfirm`, `-y`, `autoremove` (BleachBit, Kudu and several ports): they leave no downgrade path or remove packages the user never picked.
- Root `rm -rf` of a selected list, wiping `/var/log`, `/tmp`, `~/.cache` or the Trash wholesale or by directory age (Stacer, cylon and several ports).
- Leftovers matched by substring or package name with a single confirmation (two ports): Mole matches exact ids and shows a review list.
- Running the whole tool as root, or editing PAM for fingerprint sudo (two ports).
- Stopping another power daemon (auto-cpufreq); CPU governor, EPP, turbo, sysctl and `drop_caches` belong to TLP and its peers.
- Playwright and Cypress browser downloads as cache rules (Cleanr): Mole CLI (macOS) protects them because each revision is a 100 to 500 MB download (tw93/Mole#1400). tracker3, ibus and winetricks were refused too: an index database, a learned dictionary, and downloads that are no longer online.
- `ldd` on package binaries (rebuild-detector): it can run the file's own loader.
- antidot's data: its MIT license template was never filled in with a holder.

## Community Linux ports of Mole

Ten ports were read on 2026-11-01, nothing executed. None was forked from or copied into this branch. What they settled for Mole:

- A fresh branch rather than a patched `main`: the most complete fork still called BSD `stat -f` in its delete staging, where GNU `stat -f` means filesystem status, and still staged deletes into `~/.Trash`.
- One mutation sink with an identity recheck, and a freedesktop Trash with `O_EXCL` trashinfo and percent-encoded paths, as one Rust port does.
- Package inventory with `LC_ALL=C`, validated ids and the manager's own preview and confirmation, as one GTK port does; the Omarchy test VM runs in Chinese, so no output text is ever matched.
- Container engines only through their own CLI, volumes reported and never deleted.

## Open

- dnf and zypper rules come with Fedora and openSUSE support. ncdu (code.blicky.net) could not be cloned on 2026-11-02 (TLS reset); gdu, dust and dua already cover what it would add.
- Not verified on hardware: AMD GPU sysfs names, every battery driver's field names, per-process GPU memory on a real GPU.
