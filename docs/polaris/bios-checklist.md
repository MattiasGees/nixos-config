# polaris — BIOS/UEFI Checklist

Set these before installing NixOS. Exact menu names vary by motherboard (this
is an AMD board); use your board manual to locate each toggle.

## Required

- **Boot mode: UEFI** only. **Disable CSM / Legacy** boot.
- **Secure Boot: Disabled.** (NixOS boots via systemd-boot without it; secure
  boot via `lanzaboote` is a possible future item, out of scope for Phase 1.)
- **SVM / AMD-V: Enabled** — CPU virtualization, required for libvirt/KVM.
- **IOMMU / AMD-Vi: Enabled** — enable *now* even though GPU passthrough is a
  future phase; it avoids a second BIOS trip later. Pairs with the
  `amd_iommu=on iommu=pt` kernel params already set in `machines/polaris.nix`.
- **SATA/NVMe mode: AHCI** — NOT motherboard "RAID"/fake-RAID. We use ZFS
  software RAID exclusively; hardware/fake-RAID would hide the raw disks.
- **Restore on AC Power Loss: Power On** — the server should come back up after
  a power outage.

## Recommended

- **Above 4G Decoding: Enabled** and **Resizable BAR: Enabled** — harmless now,
  needed for future GPU passthrough.
- **Fast Boot: Disabled** — more reliable POST / device initialization.
- **Memory profile (EXPO/DOCP): optional** — enable only if the RAM is rated for
  it and stable. ZFS benefits from memory bandwidth.
- **ECC: Enabled** if the board + RAM support it (ideal for ZFS; not mandatory).
- **Fan curve** tuned for the 3 HDDs' thermals.
- **Boot order:** NVMe #1 first.
- **Wake-on-LAN:** optional, if you want remote power-on.

## Post-install verification

Run these after the first boot:

```bash
# IOMMU actually enabled
dmesg | grep -i -e IOMMU -e AMD-Vi

# No firmware complaints in the boot chain
systemd-analyze

# Disks visible by stable IDs, pools healthy
zpool status
ls -l /dev/disk/by-id/
```
