[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$RepoName,

    [string]$Description = "Model distribution repository",

    [ValidateSet("public", "private")]
    [string]$Visibility = "public",

    [string]$Owner = "",

    [string]$Token = "",

    [string]$Branch = "main",

    [switch]$SkipPush
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

function Get-AuthHeaders {
    param([Parameter(Mandatory = $true)][string]$Pat)

    return @{
        Authorization = "Bearer $Pat"
        Accept        = "application/vnd.github+json"
        "User-Agent"  = "model-repo-bootstrap"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    if ($env:GH_TOKEN) {
        $Token = $env:GH_TOKEN
    }
    elseif ($env:GITHUB_TOKEN) {
        $Token = $env:GITHUB_TOKEN
    }
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "No token provided. Use -Token or set GH_TOKEN/GITHUB_TOKEN."
}

$headers = Get-AuthHeaders -Pat $Token
$apiBase = "https://api.github.com"

$viewer = Invoke-RestMethod -Method Get -Uri "$apiBase/user" -Headers $headers
$viewerLogin = $viewer.login

if ([string]::IsNullOrWhiteSpace($Owner)) {
    $Owner = $viewerLogin
}

$repoExists = $false
try {
    $null = Invoke-RestMethod -Method Get -Uri "$apiBase/repos/$Owner/$RepoName" -Headers $headers
    $repoExists = $true
}
catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 404) {
        throw
    }
}

if (-not $repoExists) {
    $isPrivate = ($Visibility -eq "private")
    $body = @{
        name        = $RepoName
        description = $Description
        private     = $isPrivate
        auto_init   = $false
    } | ConvertTo-Json

    if ($Owner -eq $viewerLogin) {
        $null = Invoke-RestMethod -Method Post -Uri "$apiBase/user/repos" -Headers $headers -Body $body -ContentType "application/json"
    }
    else {
        $null = Invoke-RestMethod -Method Post -Uri "$apiBase/orgs/$Owner/repos" -Headers $headers -Body $body -ContentType "application/json"
    }
}

$remoteUrl = "https://github.com/$Owner/$RepoName.git"
$hasOrigin = $false
try {
    $null = (& git remote get-url origin)
    if ($LASTEXITCODE -eq 0) {
        $hasOrigin = $true
    }
}
catch {
    $hasOrigin = $false
}

if ($hasOrigin) {
    Invoke-Checked -Exe "git" -Args @("remote", "set-url", "origin", $remoteUrl)
}
else {
    Invoke-Checked -Exe "git" -Args @("remote", "add", "origin", $remoteUrl)
}

if (-not $SkipPush) {
    Invoke-Checked -Exe "git" -Args @("push", "-u", "origin", $Branch)
}

Write-Host "GitHub repository ready: https://github.com/$Owner/$RepoName"
if (-not $SkipPush) {
    Write-Host "Pushed branch '$Branch' to origin."
}
