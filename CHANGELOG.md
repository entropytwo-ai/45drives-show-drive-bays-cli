# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [SemVer](https://semver.org/).

## [2.0.0] - 2026-10-28

First published release — a rewrite of the original single-controller, 8-bay C8 script.

### Added
- **Multiple backends** with automatic fallback: `sas3ircu`, `sas2ircu`, `storcli`/`storcli64`/`perccli`,
  kernel SES (`/sys/class/enclosure`), and a positional mode for systems with no SAS HBA.
- **Multi-controller / multi-enclosure support**: every controller listed by `sas*ircu LIST` /
  `storcli show ctrlcount` is queried; one bay map is drawn per enclosure.
- **Any bay count**: uses the enclosure's reported `Numslots`/`StartSlot` (or highest populated slot, min. 8);
  rows of up to 12 bays by default.
- CLI flags: `--controller`, `--bays`, `--cols`, `--backend`, `--wide`, `--no-smart`, `--no-viz`, `--no-raid`,
  `--no-color`, `--color`, `--json`, `--version`, `--help`.
- **NVMe** (`/dev/nvme*n*`) and virtio disks scanned for WWN/serial matching.
- **SMART** health column (PASSED/FAILED) when `smartctl` is installed; temperature with `--wide` (ATA, SAS, NVMe).
- Disks not behind the HBA (boot SSDs, onboard SATA, NVMe) are listed in the drive table.
- New bay states in the visualization: **rebuilding** (blue) and **failed** (red); plain-text codes
  (`R/S/B/F/P/.`) in `--no-color` mode.
- Colour-coded State/Health columns (red = failed, yellow = degraded/rebuilding, green = optimal/ready).
- JSON output including drives and mdadm arrays.
- `install.sh` (with dependency check and `--uninstall`), README and this changelog.

### Changed
- `set -euo pipefail`, `trap`-based cleanup and modular functions (`detect_controllers`, `build_wwn_cache`,
  `print_drive_table`, `print_bay_viz`, `print_raid_summary`, …).
- **Performance**: a WWN/serial → device cache is built once (one `udevadm` call per disk) instead of re-scanning
  every `/dev/sd?` for every drive; `mdadm --detail` is called once per array and reused.
- Colour is disabled automatically when output is not a terminal or `NO_COLOR` is set.
- Size column computed in decimal TB from the HBA's MB value.

### Fixed
- Hot-spare detection no longer relies on a bare `/spare/` match; member roles are parsed from the mdadm device
  table (`active sync`, `spare`, `spare rebuilding`, `faulty`).
- Degraded detection now uses `Failed Devices`, the array `State` and active-vs-raid counts; `FAILED`/`inactive`
  arrays are reported as such.
- Arrays are taken from `/proc/mdstat` device names and shown with their `/dev/md/<name>` name; mount matching
  uses `lsblk` (works for `/dev/md/name`, LVM on md, and swap).
- RAID members on partitions (e.g. `sda1`, `nvme0n1p2`) are mapped to their parent disk/bay.
- `Unit Serial No(VPD)` no longer overwrites the drive serial; enclosure-services devices are no longer listed as
  drives; non-GNU `awk` compatible parsing (no `match()` array argument).
- `/dev/sd?` glob replaced with `lsblk`, so systems with more than 26 disks (`sdaa`, …) are handled.
- Temp files are cleaned up on exit/interrupt.

## [1.0.0] - original

- Initial script: single `sas3ircu` controller 0, fixed 8-bay (2×4) layout, mdadm membership and rebuild progress.
