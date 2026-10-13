param(
    [string]$InputBin,
    [string]$OutputDir = "extracted"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $InputBin) {
    throw "Usage: .\tools\Unpack-MmiFirmware.ps1 -InputBin .\GEMINI_PACK.BIN -OutputDir .\extracted"
}

function Read-AsciiZ {
    param([byte[]]$Bytes, [int64]$Offset, [int]$Length)
    $n = 0
    while ($n -lt $Length -and ($Offset + $n) -lt $Bytes.Length -and $Bytes[$Offset + $n] -ne 0) {
        $n++
    }
    return [Text.Encoding]::ASCII.GetString($Bytes, [int]$Offset, $n)
}

function Find-Ascii {
    param([byte[]]$Bytes, [string]$Text)
    $s = [Text.Encoding]::ASCII.GetString($Bytes)
    return $s.IndexOf($Text, [StringComparison]::Ordinal)
}

function Get-Md5Hex {
    param([byte[]]$Bytes, [int64]$Offset, [int64]$Length)
    $md5 = [Security.Cryptography.MD5]::Create()
    $ms = [IO.MemoryStream]::new($Bytes, [int]$Offset, [int]$Length, $false)
    try {
        $hash = $md5.ComputeHash($ms)
        return (($hash | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        $ms.Dispose()
        $md5.Dispose()
    }
}

function Convert-ToSafePartName {
    param([string]$Name, [int]$Index)
    $base = $Name.TrimEnd(".")
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = "part_$Index"
    }
    return ($base -replace "[^A-Za-z0-9_.-]", "_")
}

function Get-PartKind {
    param([byte[]]$Bytes, [int64]$Offset, [int64]$Size)
    if ($Size -lt 4 -or $Offset + 4 -gt $Bytes.Length) {
        return "empty"
    }

    $b0 = $Bytes[$Offset]
    $b1 = $Bytes[$Offset + 1]
    $b2 = $Bytes[$Offset + 2]
    $b3 = $Bytes[$Offset + 3]

    if ($b0 -eq 0x27 -and $b1 -eq 0x05 -and $b2 -eq 0x19 -and $b3 -eq 0x56) { return "uImage" }
    if ($b0 -eq 0x68 -and $b1 -eq 0x73 -and $b2 -eq 0x71 -and $b3 -eq 0x73) { return "squashfs" }
    if ($b0 -eq 0x50 -and $b1 -eq 0x41 -and $b2 -eq 0x52 -and $b3 -eq 0x54) { return "PART" }
    if ($b0 -eq 0x58 -and $b1 -eq 0x42 -and $b2 -eq 0x55 -and $b3 -eq 0x54) { return "XBUT" }
    if ($b0 -eq 0xFE -and $b1 -eq 0x49 -and $b2 -eq 0x4D -and $b3 -eq 0x47) { return "IMG" }
    if ($b0 -eq 0xFD -and $b1 -eq 0x50 -and $b2 -eq 0x4E -and $b3 -eq 0x4C) { return "PNL" }
    if ($b0 -eq 0xFA -and $b1 -eq 0x54 -and $b2 -eq 0x56 -and $b3 -eq 0x44) { return "TVD" }
    return "raw"
}

function Get-SquashFsInfo {
    param([byte[]]$Bytes, [int64]$Offset, [int64]$Size)
    if ((Get-PartKind $Bytes $Offset $Size) -ne "squashfs") {
        return $null
    }

    $mkfs = [BitConverter]::ToUInt32($Bytes, [int]($Offset + 8))
    $info = [ordered]@{
        inodes = [BitConverter]::ToUInt32($Bytes, [int]($Offset + 4))
        mkfsTime = ([DateTimeOffset]::FromUnixTimeSeconds($mkfs)).ToString("yyyy-MM-dd HH:mm:ss zzz")
        blockSize = [BitConverter]::ToUInt32($Bytes, [int]($Offset + 12))
        fragments = [BitConverter]::ToUInt32($Bytes, [int]($Offset + 16))
        compression = [BitConverter]::ToUInt16($Bytes, [int]($Offset + 20))
        blockLog = [BitConverter]::ToUInt16($Bytes, [int]($Offset + 22))
        flags = ("0x{0:X}" -f [BitConverter]::ToUInt16($Bytes, [int]($Offset + 24)))
        ids = [BitConverter]::ToUInt16($Bytes, [int]($Offset + 26))
        version = ("{0}.{1}" -f [BitConverter]::ToUInt16($Bytes, [int]($Offset + 28)), [BitConverter]::ToUInt16($Bytes, [int]($Offset + 30)))
        bytesUsed = ("0x{0:X}" -f [BitConverter]::ToUInt64($Bytes, [int]($Offset + 40)))
    }
    return $info
}

$inputPath = (Resolve-Path -LiteralPath $InputBin).Path
$bytes = [IO.File]::ReadAllBytes($inputPath)

$format = "unknown"
$imageBase = -1
$offsetBase = 0
$outer = $null

$magic6 = Read-AsciiZ $bytes 0 6
$magic16 = Read-AsciiZ $bytes 0 16

if ($magic6 -eq "GEMINI") {
    $format = "GEMINI_PACK"
    $payloadSize = [BitConverter]::ToUInt32($bytes, 0xD8)
    $payloadOffset = [BitConverter]::ToUInt32($bytes, 0xDC)
    $payloadName = Read-AsciiZ $bytes 0xC0 0x20
    $payloadMd5 = Read-AsciiZ $bytes 0xEA 0x20
    $imageBase = [int64]$payloadOffset
    $offsetBase = $imageBase
    $outer = [ordered]@{
        product = Read-AsciiZ $bytes 0x40 0x40
        sdkVersion = Read-AsciiZ $bytes 0x80 0x40
        payloadName = $payloadName
        payloadOffset = ("0x{0:X}" -f $payloadOffset)
        payloadSize = ("0x{0:X}" -f $payloadSize)
        payloadMd5 = $payloadMd5
        payloadMd5Offset = "0xEA"
        payloadMd5Ok = ((Get-Md5Hex $bytes $payloadOffset $payloadSize) -eq $payloadMd5)
    }
} elseif ($magic16 -eq "Gemini_ISP_image") {
    $format = "ISP_UPDT"
    $imageBase = 0
    $offsetBase = 0
} elseif ((Read-AsciiZ $bytes 0 4) -eq "XBUT") {
    $format = "XBUT"
    $imageBase = Find-Ascii $bytes "Gemini_ISP_image"
    $offsetBase = 0
    if ($imageBase -lt 0) {
        throw "XBUT file found, but no embedded Gemini_ISP_image was found."
    }
} else {
    throw "Unsupported firmware format. Magic at 0 is '$magic16'."
}

if ((Read-AsciiZ $bytes $imageBase 16) -ne "Gemini_ISP_image") {
    throw ("Gemini_ISP_image not found at expected offset 0x{0:X}." -f $imageBase)
}

$tableOffset = $imageBase + 0x880
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OutputDir "parts") | Out-Null

if ($format -eq "GEMINI_PACK") {
    $payloadPath = Join-Path $OutputDir "ISP_UPDT.BIN"
    $payloadSizeInt = [int]([BitConverter]::ToUInt32($bytes, 0xD8))
    $payloadOffsetInt = [int]([BitConverter]::ToUInt32($bytes, 0xDC))
    $payload = New-Object byte[] $payloadSizeInt
    [Array]::Copy($bytes, $payloadOffsetInt, $payload, 0, $payloadSizeInt)
    [IO.File]::WriteAllBytes($payloadPath, $payload)
}

$manifest = [ordered]@{
    source = $inputPath
    sourceSize = $bytes.Length
    format = $format
    imageBase = ("0x{0:X}" -f $imageBase)
    tableOffset = ("0x{0:X}" -f $tableOffset)
    offsetBase = ("0x{0:X}" -f $offsetBase)
    outer = $outer
    entries = @()
}

$seen = @{}
$blankRun = 0
$index = 0

for ($entryOffset = $tableOffset; $entryOffset -lt ($tableOffset + 0x4000); $entryOffset += 0x80) {
    $name = Read-AsciiZ $bytes $entryOffset 0x20
    if ([string]::IsNullOrWhiteSpace($name)) {
        if ($manifest.entries.Count -gt 0) {
            $blankRun++
            if ($blankRun -ge 4) { break }
        }
        continue
    }
    $blankRun = 0
    $index++

    $md5 = Read-AsciiZ $bytes ($entryOffset + 0x20) 0x20
    $relativeOffset = [BitConverter]::ToUInt32($bytes, [int]($entryOffset + 0x44))
    $size = [BitConverter]::ToUInt32($bytes, [int]($entryOffset + 0x48))
    $flashOffset = [BitConverter]::ToUInt32($bytes, [int]($entryOffset + 0x4C))
    $partitionSize = [BitConverter]::ToUInt32($bytes, [int]($entryOffset + 0x50))
    $type = [BitConverter]::ToUInt32($bytes, [int]($entryOffset + 0x54))
    $absOffset = [int64]$offsetBase + [int64]$relativeOffset

    $safe = Convert-ToSafePartName $name $index
    if ($seen.ContainsKey($safe)) {
        $seen[$safe]++
        $safe = "{0}_{1}" -f $safe, $seen[$safe]
    } else {
        $seen[$safe] = 1
    }

    $partFile = $null
    $md5Ok = $false
    $kind = "empty"
    $squashfs = $null

    if ($size -eq 0) {
        $md5Ok = ($md5 -eq "d41d8cd98f00b204e9800998ecf8427e")
    } elseif ($absOffset + $size -le $bytes.Length) {
        $partFile = "parts/$safe.bin"
        $partPath = Join-Path $OutputDir ($partFile -replace "/", "\")
        $part = New-Object byte[] ([int]$size)
        [Array]::Copy($bytes, $absOffset, $part, 0, [int]$size)
        [IO.File]::WriteAllBytes($partPath, $part)
        $md5Ok = ((Get-Md5Hex $bytes $absOffset $size) -eq $md5)
        $kind = Get-PartKind $bytes $absOffset $size
        $squashfs = Get-SquashFsInfo $bytes $absOffset $size
    } else {
        Write-Warning ("Skipping {0}: offset+size is outside file." -f $name)
    }

    $manifest.entries += [ordered]@{
        name = $name
        file = $partFile
        kind = $kind
        md5 = $md5
        md5Ok = $md5Ok
        tableEntryOffset = ("0x{0:X}" -f $entryOffset)
        offset = ("0x{0:X}" -f $relativeOffset)
        absOffset = ("0x{0:X}" -f $absOffset)
        size = ("0x{0:X}" -f $size)
        flashOffset = ("0x{0:X}" -f $flashOffset)
        partitionSize = ("0x{0:X}" -f $partitionSize)
        type = ("0x{0:X}" -f $type)
        squashfs = $squashfs
    }
}

$manifestPath = Join-Path $OutputDir "manifest.json"
$manifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding ASCII $manifestPath

Write-Host ("Extracted {0} entries from {1} to {2}" -f $manifest.entries.Count, $format, (Resolve-Path $OutputDir).Path)
Write-Host ("Manifest: {0}" -f (Resolve-Path $manifestPath).Path)
