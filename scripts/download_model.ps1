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

    [switch]$KeepTemp,

    [switch]$KeepChunks,

    [switch]$SkipAssemble
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

    $parsed = $raw | ConvertFrom-Json
    if ($parsed -is [System.Array]) {
        return @($parsed)
    }

    if ($null -eq $parsed.models) {
        return @()
    }

    return @($parsed.models)
}

function Load-SplitManifestEntries {
    param([Parameter(Mandatory = $true)][string]$SplitManifestPath)

    if (-not (Test-Path -LiteralPath $SplitManifestPath)) {
        return @()
    }

    $raw = Get-Content -LiteralPath $SplitManifestPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $parsed = $raw | ConvertFrom-Json
    if ($parsed -is [System.Array]) {
        return @($parsed)
    }

    if ($null -eq $parsed.files) {
        return @()
    }

    return @($parsed.files)
}

function Assemble-SplitFiles {
    param(
        [Parameter(Mandatory = $true)][string]$ModelDir,
        [switch]$KeepChunks
    )

    $splitManifestPath = Join-Path $ModelDir "_split_manifest.json"
    $entries = Load-SplitManifestEntries -SplitManifestPath $splitManifestPath
    if ($entries.Count -eq 0) {
        return 0
    }

    $assembledCount = 0
    $buffer = New-Object byte[] (8MB)

    foreach ($entry in $entries) {
        if (-not ($entry.PSObject.Properties.Name -contains "original_path")) {
            continue
        }
        if (-not ($entry.PSObject.Properties.Name -contains "chunks")) {
            continue
        }

        $originalRel = [string]$entry.original_path
        $targetFile = Join-Path $ModelDir ($originalRel -replace '/', '\')
        $targetParent = Split-Path -Parent $targetFile
        if (-not (Test-Path -LiteralPath $targetParent)) {
            New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
        }

        if (Test-Path -LiteralPath $targetFile) {
            Remove-Item -LiteralPath $targetFile -Force
        }

        $output = [System.IO.File]::Open($targetFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            foreach ($chunkRel in @($entry.chunks)) {
                $chunkPath = Join-Path $ModelDir (($chunkRel.ToString()) -replace '/', '\')
                if (-not (Test-Path -LiteralPath $chunkPath)) {
                    throw "Missing chunk file: $chunkRel"
                }

                $input = [System.IO.File]::OpenRead($chunkPath)
                try {
                    while ($true) {
                        $read = $input.Read($buffer, 0, $buffer.Length)
                        if ($read -le 0) {
                            break
                        }
                        $output.Write($buffer, 0, $read)
                    }
                }
                finally {
                    $input.Dispose()
                }
            }
        }
        finally {
            $output.Dispose()
        }

        if ($entry.PSObject.Properties.Name -contains "original_size_bytes") {
            $actual = (Get-Item -LiteralPath $targetFile).Length
            if ([int64]$actual -ne [int64]$entry.original_size_bytes) {
                throw "Assembled file size mismatch for '$originalRel'. Expected $($entry.original_size_bytes), got $actual."
            }
        }

        if (-not $KeepChunks) {
            foreach ($chunkRel in @($entry.chunks)) {
                $chunkPath = Join-Path $ModelDir (($chunkRel.ToString()) -replace '/', '\')
                if (Test-Path -LiteralPath $chunkPath) {
                    Remove-Item -LiteralPath $chunkPath -Force
                }
            }
        }

        $assembledCount++
    }

    return $assembledCount
}

Invoke-Checked -Exe "git" -Args @("--version")
Invoke-Checked -Exe "git" -Args @("lfs", "version")

$repoUrl = "https://github.com/$Repo.git"
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("model-download-" + [System.Guid]::NewGuid().ToString("N"))
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

    $assembledCount = 0
    if (-not $SkipAssemble) {
        $assembledCount = Assemble-SplitFiles -ModelDir $destModelDir -KeepChunks:$KeepChunks
    }

    Write-Host "Model '$Model' downloaded successfully."
    Write-Host "Repository : $Repo"
    Write-Host "Reference  : $Ref"
    Write-Host "Output path: $destModelDir"
    if (-not $SkipAssemble) {
        Write-Host "Assembled split files: $assembledCount"
    }
}
finally {
    if (-not $KeepTemp -and (Test-Path -LiteralPath $tempDir)) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}
