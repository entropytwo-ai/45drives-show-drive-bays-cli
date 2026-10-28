# show-drive-bays

A single-file Bash CLI that shows **which physical drive bay holds which Linux disk**, how each disk is used by
**mdadm software RAID**, its **SMART health / temperature**, and draws an **ASCII map of the front of every
enclosure** — colour-coded so a failed or rebuilding drive is obvious at a glance.

It started life as a mapper for a 45Drives C8 (8 bays, LSI SAS3 HBA) and now works on a wide range of servers:
multiple HBAs, multiple enclosures, any bay count, LSI SAS2/SAS3, MegaRAID/storcli, generic SES backplanes, NVMe,
and even machines with no HBA at all.

---

## Features

- **Auto-detects the storage backend** — `sas3ircu` → `sas2ircu` → `storcli`/`storcli64` → kernel SES
  (`/sys/class/enclosure`) → plain positional list.
- **All controllers & enclosures** — iterates every controller reported by the HBA tool and draws one bay map per
  enclosure. Restrict to one with `--controller N`.
- **Any chassis size** — bay count is taken from the enclosure's reported slot count (or the highest populated slot,
  min. 8). Override with `--bays` / `--cols`. Rows hold up to 12 bays by default.
- **Fast WWN matching** — every `/dev/sd*`, `/dev/nvme*n*` (and `vd*`) disk is queried once with `udevadm`; drives
  are matched by WWN, then serial (with safe fallbacks for truncated SAS serials and port-vs-LU WWNs).
- **mdadm aware** — array membership and role per disk (active / spare / rebuilding / faulty), partitions mapped to
  their parent disk, `/dev/md/<name>` names, degraded detection via `Failed Devices`, rebuild/resync/check progress,
  mount point and usage (including swap).
- **SMART** — health column (PASSED/FAILED) when `smartctl` is installed; `--wide` adds drive temperature.
- **Disks outside the HBA** (boot SSDs, onboard SATA, NVMe) are listed too, so nothing is missed.
- **Scriptable** — `--json` output, `--no-color` for logs (colour is also disabled automatically when piped).

## Supported hardware

| Backend    | Hardware                                                                                   |
|------------|--------------------------------------------------------------------------------------------|
| `sas3ircu` | Broadcom/LSI SAS3 HBAs: 9300-8i/16i, 9305-16i/24i, 9400-series (IT or IR firmware)          |
| `sas2ircu` | Broadcom/LSI SAS2 HBAs: 9201, 9207, 9211, 9240 / IBM M1015 crossflashed, etc.                |
| `storcli`  | Broadcom MegaRAID and 94xx/95xx tri-mode adapters (`storcli`, `storcli64`, Dell `perccli`)  |
| `ses`      | Any HBA/expander/backplane exposing SES slots through `/sys/class/enclosure`                |
| `none`     | No SAS HBA — onboard SATA, NVMe-only, VMs. Disks are shown positionally; RAID summary still works |

45Drives systems known to fit these backends include the **Storinator** (AV15, Q30, S45, XL60), **Stornado**,
**HomeLab HL15 / HL8 / HL4**, **Proxinator** and **C8**. Servers from other vendors work as long as one of the
backends above is available.

## Requirements

| Tool                 | Package (Debian/Ubuntu · RHEL/Rocky)   | Required?                                   |
|----------------------|----------------------------------------|---------------------------------------------|
| `bash` ≥ 4.3         | bash                                   | yes                                         |
| `lsblk`              | util-linux                             | yes                                         |
| `udevadm`            | udev / systemd                         | strongly recommended (WWN matching)         |
| `sas3ircu` / `sas2ircu` / `storcli64` | Broadcom download      | optional (needed for exact bay positions on LSI HBAs) |
| `mdadm`              | mdadm                                  | optional (RAID summary)                     |
| `smartctl`           | smartmontools                          | optional (health / temperature)             |

The script calls `sudo` for `sas*ircu`, `storcli`, `mdadm` and `smartctl` when not run as root.

## Installation

```bash
git clone https://github.com/entropytwo-ai/45drives-show-drive-bays-cli.git
cd 45drives-show-drive-bays-cli
./install.sh                 # installs /usr/local/bin/show-drive-bays
```

The installer reports missing dependencies but never blocks the install.

```bash
PREFIX=/opt ./install.sh     # install to /opt/bin instead
./install.sh --uninstall     # remove
```

Or just run it in place: `./show-drive-bays.sh`.

## Usage

```
show-drive-bays [options]

  -c, --controller N   Only query HBA controller N (default: all detected)
  -b, --bays N         Bays per enclosure in the visualization
                       (default: enclosure slot count, else highest populated slot, min 8)
      --cols N         Bays per row in the visualization (default: auto, max 12)
  -B, --backend NAME   Force backend: auto|sas3ircu|sas2ircu|storcli|ses|none
  -w, --wide           Add a temperature column (requires smartctl)
      --no-smart       Skip smartctl queries (faster)
      --no-viz         Skip the bay visualization
      --no-raid        Skip the mdadm RAID summary
      --no-color       Disable ANSI colors (NO_COLOR env var is honoured too)
      --color          Force colors even when piped
  -j, --json           JSON output (drives + arrays)
  -V, --version        Print version
  -h, --help           Show help
```

### Examples

```bash
show-drive-bays                          # auto-detect everything
show-drive-bays --wide                   # add temperatures
show-drive-bays --controller 1           # second HBA only
show-drive-bays --bays 15 --cols 15      # Storinator AV15: one row of 15
show-drive-bays --bays 60 --cols 15      # Storinator XL60: 4 rows of 15
show-drive-bays --backend ses            # use kernel SES data instead of sas3ircu
show-drive-bays --no-color > /var/log/drive-bays.txt
show-drive-bays --json | jq -r '.drives[] | select(.health == "FAILED") | .device'
show-drive-bays --json | jq '.arrays[] | select(.state | test("degraded"))'
```

### Auto layout rules

| Bays | Default layout |
|------|----------------|
| ≤ 8  | 2 rows (e.g. 8 → 2×4, matching the C8 front panel) |
| > 8  | `rows = ceil(bays / 12)`, `cols = ceil(bays / rows)` — e.g. 12 → 1×12, 15 → 2×8, 24 → 2×12, 45 → 4×12, 60 → 5×12 |

Use `--cols` to match your chassis exactly. Slots are numbered left-to-right, top-to-bottom starting at the
enclosure's `StartSlot`.

## Example output

Two LSI SAS3008 HBAs, a degraded RAID 6 rebuilding onto a spare, one failed SAS drive, plus boot devices
(`--wide --no-color`; on a terminal the bays and states are colour-coded):

```

════════════════════════════════════════════════════════════════════════════════
 Drives (backend: sas3ircu via sas3ircu, controller(s): 0 1)
════════════════════════════════════════════════════════════════════════════════
Ctl  Encl Slot Device         Model                  Serial               FW       SizeTB  State                Health  Temp  Array            Role
----------------------------------------------------------------------------------------------------------------------------------------------------------------
0    2    0    /dev/sda       ST4000NM0035-1V4       ZC120000             TN03     4.00    Ready (RDY)          PASSED  34C   data             active
0    2    1    /dev/sdb       ST4000NM0035-1V4       ZC120001             TN03     4.00    Ready (RDY)          PASSED  34C   data             active
0    2    2    /dev/sdc       ST4000NM0035-1V4       ZC120002             TN03     4.00    Ready (RDY)          PASSED  34C   data             rebuilding
0    2    3    /dev/sdd       ST4000NM0035-1V4       ZC120003             TN03     4.00    Ready (RDY)          PASSED  34C   data             active
0    2    5    /dev/sde       ST4000NM0035-1V4       ZC120005             TN03     4.00    Ready (RDY)          PASSED  34C   data             spare
1    3    14   /dev/sdf       HUH721008AL5200        7SGXYZAB             A21D     8.00    Failed (FLD)         FAILED  52C   -                -
-    -    -    /dev/sdg       Micron 5300            BOOT1                D3MU     4.00    Present              PASSED  34C   swap             active
-    -    -    /dev/nvme0n1   Samsung SSD 970        S4EWNX0N             -        4.00    Present              PASSED  41C   swap             active

════════════════════════════════════════════════════════════════════════════════
 Drive Bay Layout — controller 0, enclosure 2 (8 bays, 2x4, slots 0-7)
════════════════════════════════════════════════════════════════════════════════
  ┌─────────────────────────┐
  │ [0:R] [1:R] [2:B] [3:R] │
  │ [4:.] [5:S] [6:.] [7:.] │
  └─────────────────────────┘

════════════════════════════════════════════════════════════════════════════════
 Drive Bay Layout — controller 1, enclosure 3 (15 bays, 2x8, slots 0-14)
════════════════════════════════════════════════════════════════════════════════
  ┌─────────────────────────────────────────────────────────┐
  │ [00:.] [01:.] [02:.] [03:.] [04:.] [05:.] [06:.] [07:.] │
  │ [08:.] [09:.] [10:.] [11:.] [12:.] [13:.] [14:F]        │
  └─────────────────────────────────────────────────────────┘

 Legend: R=RAID member  S=Hot spare  B=Rebuilding  F=Failed  P=Populated (non-RAID)  .=Empty

════════════════════════════════════════════════════════════════════════════════
 RAID Array Summary (mdadm)
════════════════════════════════════════════════════════════════════════════════
Array          Level    SizeGiB   State                        Members                  HotSpare       Mount/Usage
-----------------------------------------------------------------------------------------------------------------------------
data (md0)     raid6    7451.8    degraded [recovery 17.3%]    sda sdb sdc(R) sdd       sde            /srv/data
swap (md1)     raid1    8.0       clean                        nvme0n1p2 sdg2           -              swap

```

Bay codes: **R** RAID member (green), **S** hot spare (magenta), **B** rebuilding (blue), **F** failed (red),
**P** populated but not in RAID (yellow), **.** empty (cyan). In colour mode the letter is replaced by the background
colour.

## Bay count reference (45Drives)

Typical bay counts — verify against your exact model/backplane; `--bays` / `--cols` override everything.

| Model                         | Bays | Suggested flags            |
|-------------------------------|------|----------------------------|
| HomeLab HL4                   | 4    | `--bays 4`                 |
| HomeLab HL8 / C8              | 8    | (auto, 2×4)                |
| HomeLab HL15                  | 15   | `--bays 15`                |
| Storinator AV15               | 15   | `--bays 15 --cols 15`      |
| Storinator Q30                | 30   | `--bays 30 --cols 15`      |
| Stornado (2U, all-SSD)        | 32   | `--bays 32 --cols 16`      |
| Storinator S45                | 45   | `--bays 45 --cols 15`      |
| Storinator XL60               | 60   | `--bays 60 --cols 15`      |

When drives span several HBAs (common on Storinators) each controller/enclosure gets its own map; slot numbers are
those reported by the HBA.

## Troubleshooting

- **Device column shows `-`** — the HBA's WWN/serial didn't match any disk known to udev. Check
  `udevadm info --query=property --name=/dev/sdX | grep -E 'WWN|SERIAL'` against the HBA output.
- **"no supported SAS HBA or SES enclosure detected"** — install `sas3ircu`/`sas2ircu`/`storcli64` from Broadcom,
  or load the `ses` kernel module (`modprobe ses`) so `/sys/class/enclosure` is populated.
- **Wrong bay count** — some HBAs report a virtual enclosure with 8 slots per port; use `--bays`.

## Testing without hardware

`MDSTAT_FILE` and `SYSFS_ENCLOSURE` environment variables override `/proc/mdstat` and `/sys/class/enclosure`, so
the script can be exercised with mock `sas3ircu`/`mdadm`/`udevadm`/`lsblk` binaries placed first in `PATH`.

## License

See [LICENSE](LICENSE).
