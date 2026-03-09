[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string]$Source,

    [string]$Description = "",

    [switch]$Overwrite,

    [ValidateRange(128, 2047)]
    [int]$ChunkSizeMB = 1900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$GitHubLfsMaxObjectBytes = [int64]2147483648
$chunkSizeBytes = [int64]$ChunkSizeMB * 1MB
if ($chunkSizeBytes -ge $GitHubLfsMaxObjectBytes) {
    throw "ChunkSizeMB must be less than 2048 MB to satisfy GitHub LFS object limits."
}

function Get-RepoRoot {
    $scriptDir = Split-Path -Parent $PSCommandPath
    return (Resolve-Path (Join-Path $scriptDir "..")).Path
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $base = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
    $target = [System.IO.Path]::GetFullPath($TargetPath)
    $baseUri = [System.Uri]$base
    $targetUri = [System.Uri]$target
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace('\', '/')
}

function Load-Manifest {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    $defaultManifest = [ordered]@{
        version        = 1
        updated_at_utc = $null
        models         = @()
    }

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return $defaultManifest
    }

    $raw = Get-Content -LiteralPath $ManifestPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $defaultManifest
    }

    $parsed = $raw | ConvertFrom-Json
    if ($parsed -is [System.Array]) {
        return [ordered]@{
            version        = 1
            updated_at_utc = $null
            models         = @($parsed)
        }
    }

    $models = @()
    if ($null -ne $parsed.models) {
        $models = @($parsed.models)
    }

    return [ordered]@{
        version        = if ($null -ne $parsed.version) { $parsed.version } else { 1 }
        updated_at_utc = $parsed.updated_at_utc
        models         = $models
    }
}

function Copy-FileWithAutoSplit {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$ModelRoot,
        [Parameter(Mandatory = $true)][int64]$ChunkSizeBytes,
        [Parameter(Mandatory = $true)][int64]$MaxObjectBytes,
        [Parameter(Mandatory = $true)][ref]$SplitRecords
    )

    $sourceItem = Get-Item -LiteralPath $SourcePath
    $parentDir = Split-Path -Parent $DestinationPath
    if (-not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    if ([int64]$sourceItem.Length -le $MaxObjectBytes) {
        Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
        return
    }

    Write-Host "Splitting large file: $SourcePath ($($sourceItem.Length) bytes)"

    $fileName = Split-Path -Leaf $DestinationPath
    $chunkRelativePaths = @()
    $buffer = New-Object byte[] (8MB)
    $chunkIndex = 1

    $input = [System.IO.File]::OpenRead($SourcePath)
    try {
        while ($true) {
            $chunkName = "{0}.part{1:d4}" -f $fileName, $chunkIndex
            $chunkPath = Join-Path $parentDir $chunkName
            $chunkWritten = [int64]0

            $output = [System.IO.File]::Open($chunkPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                while ($chunkWritten -lt $ChunkSizeBytes) {
                    $remaining = $ChunkSizeBytes - $chunkWritten
                    $toRead = [int][Math]::Min([int64]$buffer.Length, $remaining)
                    $read = $input.Read($buffer, 0, $toRead)
                    if ($read -le 0) {
                        break
                    }

                    $output.Write($buffer, 0, $read)
                    $chunkWritten += [int64]$read
                }
            }
            finally {
                $output.Dispose()
            }

            if ($chunkWritten -le 0) {
                Remove-Item -LiteralPath $chunkPath -Force -ErrorAction SilentlyContinue
                break
            }

            $chunkRelativePaths += Get-RelativePath -BasePath $ModelRoot -TargetPath $chunkPath
            $chunkIndex++
        }
    }
    finally {
        $input.Dispose()
    }

    if ($chunkRelativePaths.Count -eq 0) {
        throw "Split failed for '$SourcePath'. No chunks were produced."
    }

    $SplitRecords.Value += [ordered]@{
        original_path       = Get-RelativePath -BasePath $ModelRoot -TargetPath $DestinationPath
        original_name       = $fileName
        original_size_bytes = [int64]$sourceItem.Length
        chunk_size_bytes    = [int64]$ChunkSizeBytes
        chunks              = $chunkRelativePaths
    }

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Force
    }
}

function Write-SplitManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ModelRoot,
        [Parameter(Mandatory = $true)][array]$SplitRecords
    )

    $splitManifestPath = Join-Path $ModelRoot "_split_manifest.json"

    if ($SplitRecords.Count -eq 0) {
        if (Test-Path -LiteralPath $splitManifestPath) {
            Remove-Item -LiteralPath $splitManifestPath -Force
        }
        return
    }

    $splitManifest = [ordered]@{
        version        = 1
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        files          = $SplitRecords
    }

    $splitJson = $splitManifest | ConvertTo-Json -Depth 100
    Set-Content -LiteralPath $splitManifestPath -Value $splitJson -Encoding utf8
}

$repoRoot = Get-RepoRoot
$sourceItem = Get-Item -LiteralPath $Source

$modelsRoot = Join-Path $repoRoot "models"
$manifestPath = Join-Path $modelsRoot "manifest.json"
$targetModelDir = Join-Path $modelsRoot $Name

if (-not (Test-Path -LiteralPath $modelsRoot)) {
    New-Item -ItemType Directory -Path $modelsRoot -Force | Out-Null
}

if (Test-Path -LiteralPath $targetModelDir) {
    if (-not $Overwrite) {
        throw "Model '$Name' already exists. Use -Overwrite to replace it."
    }
    Remove-Item -LiteralPath $targetModelDir -Recurse -Force
}

New-Item -ItemType Directory -Path $targetModelDir -Force | Out-Null

$splitRecords = @()

if ($sourceItem.PSIsContainer) {
    $sourceRoot = (Resolve-Path -LiteralPath $sourceItem.FullName).Path
    $sourceFiles = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force)
    foreach ($sourceFile in $sourceFiles) {
        $relativePath = Get-RelativePath -BasePath $sourceRoot -TargetPath $sourceFile.FullName
        $destinationPath = Join-Path $targetModelDir ($relativePath -replace '/', '\')
        Copy-FileWithAutoSplit `
            -SourcePath $sourceFile.FullName `
            -DestinationPath $destinationPath `
            -ModelRoot $targetModelDir `
            -ChunkSizeBytes $chunkSizeBytes `
            -MaxObjectBytes $GitHubLfsMaxObjectBytes `
            -SplitRecords ([ref]$splitRecords)
    }
}
else {
    $destinationPath = Join-Path $targetModelDir $sourceItem.Name
    Copy-FileWithAutoSplit `
        -SourcePath $sourceItem.FullName `
        -DestinationPath $destinationPath `
        -ModelRoot $targetModelDir `
        -ChunkSizeBytes $chunkSizeBytes `
        -MaxObjectBytes $GitHubLfsMaxObjectBytes `
        -SplitRecords ([ref]$splitRecords)
}

Write-SplitManifest -ModelRoot $targetModelDir -SplitRecords $splitRecords

$modelFiles = @(Get-ChildItem -LiteralPath $targetModelDir -Recurse -File | Sort-Object FullName)
$fileEntries = @()
$totalSize = [int64]0

foreach ($file in $modelFiles) {
    $relativeFile = Get-RelativePath -BasePath $targetModelDir -TargetPath $file.FullName
    $totalSize += [int64]$file.Length
    $fileEntries += [ordered]@{
        path       = $relativeFile
        size_bytes = [int64]$file.Length
    }
}

$manifest = Load-Manifest -ManifestPath $manifestPath
$nowUtc = (Get-Date).ToUniversalTime().ToString("o")

$entry = [ordered]@{
    name             = $Name
    path             = "models/$Name"
    description      = $Description
    file_count       = $fileEntries.Count
    total_size_bytes = $totalSize
    files            = $fileEntries
    updated_at_utc   = $nowUtc
}

$existingIndex = -1
for ($i = 0; $i -lt $manifest.models.Count; $i++) {
    if ($manifest.models[$i].name -eq $Name) {
        $existingIndex = $i
        break
    }
}

if ($existingIndex -ge 0) {
    $manifest.models[$existingIndex] = $entry
}
else {
    $manifest.models += $entry
}

$manifest.updated_at_utc = $nowUtc
$manifest.version = 1

$json = $manifest | ConvertTo-Json -Depth 100
Set-Content -LiteralPath $manifestPath -Value $json -Encoding utf8

Write-Host "Model '$Name' registered successfully."
Write-Host "Model path : $targetModelDir"
Write-Host "Files      : $($fileEntries.Count)"
Write-Host "Total bytes: $totalSize"
Write-Host "Split files: $($splitRecords.Count)"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  git add ."
Write-Host "  git commit -m `"Add model: $Name`""
Write-Host "  git push"
