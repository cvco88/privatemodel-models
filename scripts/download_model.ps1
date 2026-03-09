[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string]$Repo,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$Model,

    [string]$Ref = "main",

    [string]$Output = ".\downloads",

    [string]$Token = "",

    [switch]$Overwrite,

    [switch]$KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Args
    )

    & $Exe @Args
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $Exe $($Args -join ' ')"
    }
}

function Load-ManifestModels {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return @()
    }

    $raw = Get-Content -LiteralPath $ManifestPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $parsed = $raw | ConvertFrom-Json -Depth 100
    if ($parsed -is [System.Array]) {
        return @($parsed)
    }

    if ($null -eq $parsed.models) {
        return @()
    }

    return @($parsed.models)
}

Invoke-Checked -Exe "git" -Args @("--version")
Invoke-Checked -Exe "git" -Args @("lfs", "version")

$repoUrl = "https://github.com/$Repo.git"
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("model-download-" + [System.Guid]::NewGuid().ToString("N"))
$outputRoot = (Resolve-Path -LiteralPath "." ).Path
if (-not (Test-Path -LiteralPath $Output)) {
    New-Item -ItemType Directory -Path $Output -Force | Out-Null
}
$resolvedOutput = (Resolve-Path -LiteralPath $Output).Path
$destModelDir = Join-Path $resolvedOutput $Model
$extraHeaderConfig = $null

if (Test-Path -LiteralPath $destModelDir) {
    if (-not $Overwrite) {
        throw "Destination exists: $destModelDir. Use -Overwrite to replace it."
    }
    Remove-Item -LiteralPath $destModelDir -Recurse -Force
}

try {
    if ([string]::IsNullOrWhiteSpace($Token)) {
        Invoke-Checked -Exe "git" -Args @(
            "clone", "--depth", "1", "--filter=blob:none", "--sparse", "--branch", $Ref, $repoUrl, $tempDir
        )
    }
    else {
        $authBytes = [System.Text.Encoding]::ASCII.GetBytes("x-access-token:$Token")
        $authValue = [System.Convert]::ToBase64String($authBytes)
        $extraHeaderConfig = "AUTHORIZATION: basic $authValue"

        Invoke-Checked -Exe "git" -Args @(
            "-c", "http.https://github.com/.extraheader=$extraHeaderConfig",
            "clone", "--depth", "1", "--filter=blob:none", "--sparse", "--branch", $Ref, $repoUrl, $tempDir
        )

        Invoke-Checked -Exe "git" -Args @(
            "-C", $tempDir, "config", "http.https://github.com/.extraheader", $extraHeaderConfig
        )
    }

    Invoke-Checked -Exe "git" -Args @(
        "-C", $tempDir, "sparse-checkout", "set", "models/$Model", "models/manifest.json"
    )

    $manifestPath = Join-Path $tempDir "models\manifest.json"
    $models = Load-ManifestModels -ManifestPath $manifestPath
    $existsInManifest = $false
    if ($models.Count -gt 0) {
        foreach ($item in $models) {
            if ($item.name -eq $Model) {
                $existsInManifest = $true
                break
            }
        }
    }

    if (-not $existsInManifest -and $models.Count -gt 0) {
        $available = ($models | ForEach-Object { $_.name } | Sort-Object) -join ", "
        throw "Model '$Model' not found in manifest. Available models: $available"
    }

    Invoke-Checked -Exe "git" -Args @(
        "-C", $tempDir, "lfs", "pull", "--include", "models/$Model/**", "--exclude", ""
    )

    $sourceModelDir = Join-Path $tempDir "models\$Model"
    if (-not (Test-Path -LiteralPath $sourceModelDir)) {
        throw "Model directory not found: models/$Model in $Repo (ref=$Ref)."
    }

    New-Item -ItemType Directory -Path $destModelDir -Force | Out-Null
    $children = Get-ChildItem -LiteralPath $sourceModelDir -Force
    foreach ($child in $children) {
        Copy-Item -LiteralPath $child.FullName -Destination $destModelDir -Recurse -Force
    }

    Write-Host "Model '$Model' downloaded successfully."
    Write-Host "Repository : $Repo"
    Write-Host "Reference  : $Ref"
    Write-Host "Output path: $destModelDir"
}
finally {
    if (-not $KeepTemp -and (Test-Path -LiteralPath $tempDir)) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}
