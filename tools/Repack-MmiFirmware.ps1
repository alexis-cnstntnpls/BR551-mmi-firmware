param(
    [string]$WorkDir = "extracted",
    [string]$OriginalBin,
    [string]$OutputBin = "GEMINI_PACK_CUSTOM.BIN",
    [switch]$SkipUImageFix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Convert-FromHexOrDecimal {
    param($Value)
    if ($null -eq $Value) { return 0L }
    $text = [string]$Value
    if ($text.StartsWith("0x", [StringComparison]::OrdinalIgnoreCase)) {
        return [Convert]::ToInt64($text.Substring(2), 16)
    }
    return [Convert]::ToInt64($text, 10)
}

function Write-AsciiFixed {
    param([byte[]]$Bytes, [int64]$Offset, [string]$Text, [int]$Length)
    $raw = [Text.Encoding]::ASCII.GetBytes($Text)
    if ($raw.Length -gt $Length) {
        throw "Text '$Text' is longer than fixed field length $Length."
    }
    [Array]::Clear($Bytes, [int]$Offset, $Length)
    [Array]::Copy($raw, 0, $Bytes, [int]$Offset, $raw.Length)
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

$script:Crc32Table = $null

function Initialize-Crc32Table {
    $table = New-Object UInt32[] 256
    [uint64]$poly = [Convert]::ToUInt64("EDB88320", 16)
    [uint64]$mask = [Convert]::ToUInt64("FFFFFFFF", 16)
    for ($i = 0; $i -lt 256; $i++) {
        [uint32]$crc = $i
        for ($j = 0; $j -lt 8; $j++) {
            if (($crc -band 1) -ne 0) {
                $crc = [uint32]((([uint64]$crc -shr 1) -bxor $poly) -band $mask)
            } else {
                $crc = [uint32](([uint64]$crc -shr 1) -band $mask)
            }
        }
        $table[$i] = $crc
    }
    $script:Crc32Table = $table
}

function Get-Crc32 {
    param([byte[]]$Bytes, [int64]$Offset, [int64]$Length)
    if ($null -eq $script:Crc32Table) { Initialize-Crc32Table }
    [uint32]$crc = [Convert]::ToUInt32("FFFFFFFF", 16)
    [uint64]$xorAll = [Convert]::ToUInt64("FFFFFFFF", 16)
    for ($i = 0L; $i -lt $Length; $i++) {
        $idx = [int]((([uint64]$crc) -bxor ([uint64]$Bytes[$Offset + $i])) -band 0xFF)
        $crc = [uint32]((([uint64]$script:Crc32Table[$idx]) -bxor ([uint64]$crc -shr 8)) -band $xorAll)
    }
    return [uint32]((([uint64]$crc) -bxor $xorAll) -band $xorAll)
}

function Read-Be32 {
    param([byte[]]$Bytes, [int64]$Offset)
    return (([uint32]$Bytes[$Offset] -shl 24) -bor ([uint32]$Bytes[$Offset + 1] -shl 16) -bor ([uint32]$Bytes[$Offset + 2] -shl 8) -bor [uint32]$Bytes[$Offset + 3])
}

function Write-Be32 {
    param([byte[]]$Bytes, [int64]$Offset, [uint32]$Value)
    $Bytes[$Offset] = [byte](($Value -shr 24) -band 0xFF)
    $Bytes[$Offset + 1] = [byte](($Value -shr 16) -band 0xFF)
    $Bytes[$Offset + 2] = [byte](($Value -shr 8) -band 0xFF)
    $Bytes[$Offset + 3] = [byte]($Value -band 0xFF)
}

function Find-AsciiInRange {
    param(
        [byte[]]$Bytes,
        [string]$Text,
        [int64]$Start,
        [int64]$Length
    )

    $needle = [Text.Encoding]::ASCII.GetBytes($Text)
    $end = [Math]::Min([int64]$Bytes.Length, $Start + $Length)
    $last = $end - $needle.Length

    for ($offset = $Start; $offset -le $last; $offset++) {
        $matches = $true
        for ($i = 0; $i -lt $needle.Length; $i++) {
            if ($Bytes[$offset + $i] -ne $needle[$i]) {
                $matches = $false
                break
            }
        }
        if ($matches) {
            return $offset
        }
    }

    return -1L
}

function Update-UImageHeader {
    param([byte[]]$PartBytes)

    if ($PartBytes.Length -lt 64) { return $false }
    if ((Read-Be32 $PartBytes 0) -ne 0x27051956) { return $false }
    if ($PartBytes[30] -eq 90) {
        return $false
    }

    $dataSize = Read-Be32 $PartBytes 12
    if ([int64]$dataSize + 64L -gt $PartBytes.Length) {
        Write-Warning ("uImage data_size 0x{0:X} is larger than this part; header was not updated." -f $dataSize)
        return $false
    }

    $dataCrc = Get-Crc32 $PartBytes 64 $dataSize
    Write-Be32 $PartBytes 24 $dataCrc

    Write-Be32 $PartBytes 4 0
    $headerCrc = Get-Crc32 $PartBytes 0 64
    Write-Be32 $PartBytes 4 $headerCrc
    return $true
}

function Update-MainUpdateScriptChecksums {
    param(
        [byte[]]$Image,
        $Manifest
    )

    if (-not $Manifest.outer -or -not $Manifest.outer.payloadOffset -or -not $Manifest.outer.payloadSize) {
        throw "GEMINI package is missing outer payload metadata."
    }

    $payloadOffset = Convert-FromHexOrDecimal $Manifest.outer.payloadOffset
    $payloadSize = Convert-FromHexOrDecimal $Manifest.outer.payloadSize
    $searchLength = [Math]::Min([int64]0x40000, $payloadSize)
    $searchStart = $payloadOffset + $payloadSize - $searchLength
    $nameOffset = Find-AsciiInRange $Image "main update script" $searchStart $searchLength
    if ($nameOffset -lt 0) {
        throw "Unable to locate the main U-Boot update script."
    }

    $headerOffset = $nameOffset - 0x20
    if ($headerOffset -lt $payloadOffset -or (Read-Be32 $Image $headerOffset) -ne 0x27051956) {
        throw ("Invalid main update script uImage header at 0x{0:X}." -f $headerOffset)
    }

    $uImageDataSize = Read-Be32 $Image ($headerOffset + 0x0C)
    $uImageDataOffset = $headerOffset + 0x40
    if ($uImageDataOffset + $uImageDataSize -gt $Image.Length) {
        throw "Main update script uImage points outside the package."
    }

    $scriptLength = Read-Be32 $Image $uImageDataOffset
    $scriptOffset = $uImageDataOffset + 8
    if ($scriptLength -gt ($uImageDataSize - 8) -or $scriptOffset + $scriptLength -gt $Image.Length) {
        throw "Invalid main update script length."
    }

    $scriptText = [Text.Encoding]::ASCII.GetString($Image, [int]$scriptOffset, [int]$scriptLength)
    $hashPattern = [regex]::new(
        'md5sum \$isp_ram_addr (0x[0-9a-fA-F]+) md5sum_value\s+if test "\$md5sum_value" = ([0-9a-fA-F]{32}) ; then',
        [Text.RegularExpressions.RegexOptions]::Multiline
    )

    foreach ($entry in $Manifest.entries) {
        if (-not $entry.file) { continue }

        $sectionMarker = "echo Updating $($entry.name) ..."
        $sectionStart = $scriptText.IndexOf($sectionMarker, [StringComparison]::Ordinal)
        if ($sectionStart -lt 0) {
            throw ("Main update script has no section for partition {0}." -f $entry.name)
        }

        $nextSection = $scriptText.IndexOf("echo Updating ", $sectionStart + $sectionMarker.Length, [StringComparison]::Ordinal)
        if ($nextSection -lt 0) {
            $nextSection = $scriptText.Length
        }

        $section = $scriptText.Substring($sectionStart, $nextSection - $sectionStart)
        $hashMatches = $hashPattern.Matches($section)
        if ($hashMatches.Count -eq 0) {
            throw ("Main update script has no verification hashes for partition {0}." -f $entry.name)
        }

        $partOffset = Convert-FromHexOrDecimal $entry.absOffset
        $partSize = Convert-FromHexOrDecimal $entry.size
        $verifiedBytes = 0L

        foreach ($match in $hashMatches) {
            $chunkSize = Convert-FromHexOrDecimal $match.Groups[1].Value
            if ($verifiedBytes + $chunkSize -gt $partSize) {
                throw ("Verification chunks exceed partition size for {0}." -f $entry.name)
            }

            $chunkMd5 = Get-Md5Hex $Image ($partOffset + $verifiedBytes) $chunkSize
            $hashOffset = $scriptOffset + $sectionStart + $match.Groups[2].Index
            Write-AsciiFixed $Image $hashOffset $chunkMd5 0x20
            $verifiedBytes += $chunkSize
        }

        if ($verifiedBytes -ne $partSize) {
            throw (
                "Verification chunks cover 0x{0:X} bytes for {1}, expected 0x{2:X}." -f
                $verifiedBytes, $entry.name, $partSize
            )
        }
    }

    $dataCrc = Get-Crc32 $Image $uImageDataOffset $uImageDataSize
    Write-Be32 $Image ($headerOffset + 0x18) $dataCrc

    Write-Be32 $Image ($headerOffset + 0x04) 0
    $headerCrc = Get-Crc32 $Image $headerOffset 0x40
    Write-Be32 $Image ($headerOffset + 0x04) $headerCrc

    Write-Host ("Updated block verification hashes in main update script at 0x{0:X}." -f $headerOffset)
}

$manifestPath = Join-Path $WorkDir "manifest.json"
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Missing manifest: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

if (-not $OriginalBin) {
    $OriginalBin = $manifest.source
}

$originalPath = (Resolve-Path -LiteralPath $OriginalBin).Path
$image = [IO.File]::ReadAllBytes($originalPath)
$tableOffset = Convert-FromHexOrDecimal $manifest.tableOffset
$offsetBase = Convert-FromHexOrDecimal $manifest.offsetBase

$index = 0
foreach ($entry in $manifest.entries) {
    $index++
    if (-not $entry.file) { continue }

    $partPath = Join-Path $WorkDir (($entry.file -replace "/", "\"))
    if (-not (Test-Path -LiteralPath $partPath)) {
        throw ("Missing part for {0}: {1}" -f $entry.name, $partPath)
    }

    $slotSize = Convert-FromHexOrDecimal $entry.size
    $absOffset = Convert-FromHexOrDecimal $entry.absOffset
    if ($absOffset -eq 0 -and $entry.offset) {
        $absOffset = $offsetBase + (Convert-FromHexOrDecimal $entry.offset)
    }

    $part = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $partPath).Path)
    if ($part.Length -gt $slotSize) {
        throw ("{0} is too large: 0x{1:X} bytes, slot is 0x{2:X} bytes." -f $entry.name, $part.Length, $slotSize)
    }

    if (-not $SkipUImageFix) {
        [void](Update-UImageHeader $part)
    }

    if ($absOffset + $slotSize -gt $image.Length) {
        throw ("{0} points outside the original image." -f $entry.name)
    }

    [Array]::Clear($image, [int]$absOffset, [int]$slotSize)
    [Array]::Copy($part, 0, $image, [int]$absOffset, $part.Length)

    $newMd5 = Get-Md5Hex $image $absOffset $slotSize
    $entryOffset = 0
    if ($entry.PSObject.Properties.Name -contains "tableEntryOffset") {
        $entryOffset = Convert-FromHexOrDecimal $entry.tableEntryOffset
    } else {
        $entryOffset = $tableOffset + (($index - 1) * 0x80)
    }
    Write-AsciiFixed $image ($entryOffset + 0x20) $newMd5 0x20
}

if ($manifest.format -eq "GEMINI_PACK") {
    Update-MainUpdateScriptChecksums $image $manifest
}

if ($manifest.outer -and $manifest.outer.payloadMd5Offset) {
    $payloadOffset = Convert-FromHexOrDecimal $manifest.outer.payloadOffset
    $payloadSize = Convert-FromHexOrDecimal $manifest.outer.payloadSize
    $payloadMd5Offset = Convert-FromHexOrDecimal $manifest.outer.payloadMd5Offset
    $payloadMd5 = Get-Md5Hex $image $payloadOffset $payloadSize
    Write-AsciiFixed $image $payloadMd5Offset $payloadMd5 0x20
}

[IO.File]::WriteAllBytes($OutputBin, $image)
Write-Host ("Wrote {0}" -f (Resolve-Path -LiteralPath $OutputBin).Path)
