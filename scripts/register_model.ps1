[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string]$Source,

    [string]$Description = "",

    [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RepoRoot {
    $scriptDir = Split-Path -Parent $PSCommandPath
    return (Resolve-Path (Join-Path $scriptDir "..")).Path
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $base = (Resolve-Path -LiteralPath $BasePath).Path.TrimEnd('\') + '\'
    $target = (Resolve-Path -LiteralPath $TargetPath).Path
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

    $parsed = $raw | ConvertFrom-Json -Depth 100
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

if ($sourceItem.PSIsContainer) {
    $children = Get-ChildItem -LiteralPath $sourceItem.FullName -Force
    foreach ($child in $children) {
        Copy-Item -LiteralPath $child.FullName -Destination $targetModelDir -Recurse -Force
    }
}
else {
    Copy-Item -LiteralPath $sourceItem.FullName -Destination (Join-Path $targetModelDir $sourceItem.Name) -Force
}

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
Write-Host ""
Write-Host "Next steps:"
Write-Host "  git add ."
Write-Host "  git commit -m `"Add model: $Name`""
Write-Host "  git push"
