[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceDir,

    [Parameter(Mandatory = $true)]
    [string]$OutputBin,

    [string]$ReferenceBin
)

$ErrorActionPreference = 'Stop'

$sourcePath = (Resolve-Path -LiteralPath $SourceDir).Path
$outputPath = [System.IO.Path]::GetFullPath($OutputBin)
$outputParent = Split-Path -Parent $outputPath

if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
    throw "SourceDir not found: $sourcePath"
}

if (-not (Test-Path -LiteralPath $outputParent)) {
    New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
}

$wslSource = "/mnt/" + $sourcePath.Substring(0,1).ToLower() + $sourcePath.Substring(2).Replace('\', '/')
$wslOutput = "/mnt/" + $outputPath.Substring(0,1).ToLower() + $outputPath.Substring(2).Replace('\', '/')

$escapedSource = $wslSource.Replace("'", "'\''")
$escapedOutput = $wslOutput.Replace("'", "'\''")

if ($ReferenceBin) {
    $referencePath = (Resolve-Path -LiteralPath $ReferenceBin).Path
    $wslReference = "/mnt/" + $referencePath.Substring(0,1).ToLower() + $referencePath.Substring(2).Replace('\', '/')
    $escapedReference = $wslReference.Replace("'", "'\''")
    $helperPath = Join-Path $PSScriptRoot "Rebuild-SquashFsFromReference.sh"
    $wslHelper = ("/mnt/" + $helperPath.Substring(0,1).ToLower() + $helperPath.Substring(2).Replace('\', '/')).Replace("'", "'\''")
    $wslCommand = @(
        "sh '$wslHelper'"
        "'$escapedReference'"
        "'$escapedSource'"
        "'$escapedOutput'"
    ) -join " "
} else {
    Write-Warning "Rebuilding directly from a Windows-mounted tree loses original Linux mode bits. Use -ReferenceBin for a flash-safe rebuild path."
    $wslCommand = @(
        "mksquashfs '$escapedSource' '$escapedOutput'"
        "-comp lzo"
        "-Xalgorithm lzo1x_999"
        "-Xcompression-level 9"
        "-b 32768"
        "-noappend"
        "-no-exports"
        "-all-root"
    ) -join " "
}

Write-Host "Rebuilding SquashFS:"
Write-Host "  Source: $sourcePath"
Write-Host "  Output: $outputPath"
if ($ReferenceBin) {
    Write-Host "  Reference: $referencePath"
}

& wsl.exe sh -lc $wslCommand
if ($LASTEXITCODE -ne 0) {
    throw "mksquashfs failed with exit code $LASTEXITCODE"
}

Get-Item -LiteralPath $outputPath | Select-Object FullName, Length
