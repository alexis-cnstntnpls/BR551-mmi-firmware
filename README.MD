# BR551 MMI Box Firmware - Clean Extraction

This directory is a clean extraction of the original BR551 firmware used by
this MMI box. It contains no custom patches. Keep it as a read-only reference
and perform experiments in a separate working copy.

## Known clean source

- Source package: `GEMINI_PACK.BIN`
- Package size: `87,104,512` bytes
- SHA-256: `026CAF0E292B74D48CE274211295ABD3028B4EF1FD58027E03FC6EFFE3BDA4E6`
- Inner payload: `ISP_UPDT.BIN`
- Extracted partition entries: 14

The firmware is not a normal disk image. `GEMINI_PACK.BIN` is an outer update
container holding an `ISP_UPDT.BIN` payload. The inner image contains a
partition table and a U-Boot update script that writes and verifies each
partition in blocks.

## Directory layout

- `manifest.json`: parsed package layout, offsets, slot sizes, partition MD5s
  and SquashFS metadata.
- `ISP_UPDT.BIN`: unmodified inner update payload extracted from the package.
- `parts/`: the 14 original partition blobs exactly as stored in the package.
- `rootfs_fs/`: minimal Linux root filesystem and boot-time system files.
- `spsdk_fs/`: platform services, hardware/network/audio support and projection
  components such as the CarPlay runtime.
- `spapp_fs/`: product applications, user interface libraries, configuration
  and embedded resources.
- `tools/`: generic unpack, SquashFS rebuild and GEMINI repack utilities. No
  modification-specific patch is included.

The remaining raw partitions contain the bootloader, kernel, logos, panel and
video configuration, runtime configuration and version metadata. Do not alter
them unless their format and role are fully understood.

## How a working custom firmware was rebuilt

The manufacturer source code was not available, so the firmware was not
recompiled from source in the traditional sense. A working image was produced
by carefully repackaging the original binaries:

1. Start from the verified stock package.
2. Extract the fixed partition layout without changing offsets.
3. Modify only the required file or resource in one filesystem.
4. Rebuild only that SquashFS partition using its original format: SquashFS
   4.0, LZO compression and 32 KiB blocks.
5. Put the rebuilt partition back into its original slot without exceeding the
   slot size or moving any following partition.
6. Refresh the partition MD5, every block-verification MD5 in the U-Boot update
   script, applicable legacy uImage CRC fields and the outer payload MD5.
7. Leave every unrelated partition and package byte unchanged.

Preserving only the visible partition MD5 is not enough. The updater verifies
partitions in blocks, so a package with stale embedded block hashes may report
`burn failed` or fail during boot.

## Requirements

Always supply your own known-good `GEMINI_PACK.BIN` and verify its SHA-256
before working. The original outer package is not duplicated in this dump.

Clone the repository with Git LFS enabled so the original partition images are
downloaded instead of remaining as small LFS pointer files:

```bash
git lfs install
git clone https://github.com/alexis-cnstntnpls/mini-r56-br551-mmi-firmware.git
cd mini-r56-br551-mmi-firmware
git lfs pull
```

Windows requires PowerShell and WSL with `python3` and `squashfs-tools`.
Linux requires `python3`, `squashfs-tools`, `jq` and PowerShell 7 (`pwsh`).
PowerShell 7 is cross-platform; it is used only for parsing and rebuilding the
vendor GEMINI container.

Example packages on Debian or Ubuntu:

```bash
sudo apt update
sudo apt install git git-lfs jq python3 squashfs-tools
pwsh --version
unsquashfs -version
```

If `pwsh` is missing, install PowerShell 7 using Microsoft's instructions for
your distribution before continuing.

## Windows / PowerShell workflow

Verify and unpack the stock update:

```powershell
$expected = "026CAF0E292B74D48CE274211295ABD3028B4EF1FD58027E03FC6EFFE3BDA4E6"
$actual = (Get-FileHash .\GEMINI_PACK.BIN -Algorithm SHA256).Hash
if ($actual -ne $expected) { throw "Unexpected stock firmware hash: $actual" }

.\tools\Unpack-MmiFirmware.ps1 `
  -InputBin .\GEMINI_PACK.BIN `
  -OutputDir .\work_br551

wsl unsquashfs -d work_br551/spapp_fs work_br551/parts/spapp.bin
```

After editing `work_br551\spapp_fs`, rebuild only that partition. Always use
the clean partition as the reference so Linux modes, symlinks and the original
filesystem timestamp are preserved:

```powershell
.\tools\Rebuild-SquashFsPart.ps1 `
  -SourceDir .\work_br551\spapp_fs `
  -ReferenceBin .\parts\spapp.bin `
  -OutputBin .\work_br551\parts\spapp.bin

.\tools\Repack-MmiFirmware.ps1 `
  -WorkDir .\work_br551 `
  -OriginalBin .\GEMINI_PACK.BIN `
  -OutputBin .\GEMINI_PACK_CUSTOM.BIN
```

Re-extract and verify the result:

```powershell
.\tools\Unpack-MmiFirmware.ps1 `
  -InputBin .\GEMINI_PACK_CUSTOM.BIN `
  -OutputDir .\verify_custom

$m = Get-Content .\verify_custom\manifest.json -Raw | ConvertFrom-Json
if (-not $m.outer.payloadMd5Ok) { throw "Invalid outer payload MD5" }
if ($m.entries.md5Ok -contains $false) { throw "Invalid partition MD5" }
$m.entries | Select-Object name, kind, size, md5Ok
```

Use the same procedure for `rootfs.bin` or `spsdk.bin` when one of those
filesystems is changed.

## Linux / Bash workflow

Verify the stock package, unpack it with cross-platform PowerShell and extract
the filesystem using native Linux tools:

```bash
expected=026CAF0E292B74D48CE274211295ABD3028B4EF1FD58027E03FC6EFFE3BDA4E6
actual=$(sha256sum GEMINI_PACK.BIN | awk '{print toupper($1)}')
test "$actual" = "$expected" || { echo "Unexpected firmware hash: $actual"; exit 1; }

pwsh ./tools/Unpack-MmiFirmware.ps1 \
  -InputBin ./GEMINI_PACK.BIN \
  -OutputDir ./work_br551

unsquashfs -d ./work_br551/spapp_fs ./work_br551/parts/spapp.bin
```

After editing `work_br551/spapp_fs`, rebuild from the clean reference and
repack the complete update:

```bash
sh ./tools/Rebuild-SquashFsFromReference.sh \
  ./parts/spapp.bin \
  ./work_br551/spapp_fs \
  ./work_br551/parts/spapp.bin

pwsh ./tools/Repack-MmiFirmware.ps1 \
  -WorkDir ./work_br551 \
  -OriginalBin ./GEMINI_PACK.BIN \
  -OutputBin ./GEMINI_PACK_CUSTOM.BIN
```

Re-extract and require every recorded MD5 check to pass:

```bash
pwsh ./tools/Unpack-MmiFirmware.ps1 \
  -InputBin ./GEMINI_PACK_CUSTOM.BIN \
  -OutputDir ./verify_custom

jq -e \
  '.outer.payloadMd5Ok == true and all(.entries[]; .md5Ok == true)' \
  ./verify_custom/manifest.json
```

Before making any modification, perform a no-change unpack/repack test and
compare it with the stock package. The files must be byte-identical. This
validates the local toolchain before hardware is involved:

```powershell
(Get-FileHash .\GEMINI_PACK.BIN -Algorithm SHA256).Hash
(Get-FileHash .\GEMINI_PACK_REBUILT.BIN -Algorithm SHA256).Hash
```

```bash
sha256sum GEMINI_PACK.BIN GEMINI_PACK_REBUILT.BIN
cmp --silent GEMINI_PACK.BIN GEMINI_PACK_REBUILT.BIN
```

## Customization guidance

- Change one subsystem at a time and keep a hash of every intermediate image.
- Prefer replacing an existing resource or applying a narrowly scoped binary
  patch over restructuring a filesystem.
- Some Qt resources are embedded inside ELF shared libraries rather than
  stored as ordinary image files. Use the Qt resource tools in `tools/` and
  preserve the surrounding binary layout whenever possible.
- Never let a rebuilt partition exceed the original `size` recorded in
  `manifest.json`. This update-image slot may be smaller than the physical
  flash `partitionSize`.
- Keep this clean dump and the original `GEMINI_PACK.BIN` untouched so the box
  can always be restored with the known-good BR551 update.
- Use this image only on compatible hardware. An interrupted flash, incorrect
  partition layout or firmware intended for another board may brick the unit.

This process validates package integrity and reproduces the vendor update
layout, but it cannot replace hardware testing. Always retain the stock update
on a separate USB drive before testing a custom build.

## Distribution notice

This repository is provided for preservation, interoperability research and
owner-performed modification of compatible hardware. It is not affiliated
with BMW, MINI, Apple or the original MMI box manufacturer. No ownership or
license is claimed over third-party firmware, trademarks or bundled software.
