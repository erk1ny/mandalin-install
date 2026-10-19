param([switch]$Check)
$ErrorActionPreference = 'Stop'
if ($Check) { Write-Host "Bootstrap check: Windows / $env:PROCESSOR_ARCHITECTURE"; return }
$originalGhToken = $env:GH_TOKEN
$originalGithubToken = $env:GITHUB_TOKEN
try {
if ([Console]::IsInputRedirected -and $env:MANDALIN_BOOTSTRAP_INTERACTIVE -ne '1') { throw 'Run setup in an interactive terminal.' }
$installHome = if ($env:MANDALIN_HOME) { $env:MANDALIN_HOME } else { Join-Path $env:USERPROFILE '.mandalin' }
$installRepo = if ($env:MANDALIN_DISTRIBUTION_REPOSITORY) { $env:MANDALIN_DISTRIBUTION_REPOSITORY } else { 'erk1ny/mandalin' }
if (-not [IO.Path]::IsPathRooted($installHome) -or $installRepo -notmatch '^[\w.-]+/[\w.-]+$') { throw 'Invalid location or repository.' }
$installArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } elseif ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') { 'x64' } else { throw 'Unsupported architecture.' }
$visibleBurp = if ($env:MANDALIN_BURP_DIR) { $env:MANDALIN_BURP_DIR } else { Join-Path $env:USERPROFILE 'Mandalin\Burp' }
if ((Read-Host "Install prebuilt Mandalin in $installHome with Burp JAR in ${visibleBurp}? [y/N]") -notmatch '^(y|yes)$') { throw 'Cancelled.' }
$env:MANDALIN_HOME = $installHome
$env:MANDALIN_DISTRIBUTION_REPOSITORY = $installRepo
$installGh = $null
foreach ($candidate in (Get-ChildItem -Path @((Join-Path $installHome 'runtimes/gh-*/bin/gh.exe'), (Join-Path $installHome 'runtimes/gh-*/extracted/bin/gh.exe')) -File -ErrorAction SilentlyContinue)) {
    & $candidate.FullName --version *> $null
    if ($LASTEXITCODE -eq 0) { $installGh = $candidate.FullName; break }
}
if (-not $installGh) {
    $candidate = Get-Command gh -ErrorAction SilentlyContinue
    if ($candidate) { & $candidate.Source --version *> $null; if ($LASTEXITCODE -eq 0) { $installGh = $candidate.Source } }
}
if (-not $installGh) {
    $ghVersion = '2.102.0'
    $ghArch = if ($installArch -eq 'x64') { 'amd64' } else { 'arm64' }
    $ghName = "gh_${ghVersion}_windows_${ghArch}.zip"
    $ghStage = Join-Path $installHome ('runtimes/gh-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $ghStage -Force | Out-Null
    Write-Host 'Downloading GitHub sign-in helper...'
    $sumsResponse = Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/cli/cli/releases/download/v$ghVersion/gh_${ghVersion}_checksums.txt" -TimeoutSec 120
    # GitHub serves release assets as application/octet-stream. Windows
    # PowerShell 5.1 returns byte[] here, unlike a text/html response.
    $sums = if ($sumsResponse.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($sumsResponse.Content) } else { [string]$sumsResponse.Content }
    $match = [regex]::Matches($sums, ('(?m)^([a-f0-9]{64})\s+' + [regex]::Escape($ghName) + '\r?$'))
    if ($match.Count -ne 1) { throw 'No unique helper checksum.' }
    $archive = Join-Path $ghStage $ghName
    Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/cli/cli/releases/download/v$ghVersion/$ghName" -OutFile $archive -TimeoutSec 600
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $match[0].Groups[1].Value) { throw 'Helper checksum mismatch.' }
    Expand-Archive -LiteralPath $archive -DestinationPath $ghStage
    $installGh = Join-Path $ghStage 'bin/gh.exe'
    & $installGh --version
    if ($LASTEXITCODE -ne 0) { throw 'GitHub helper cannot run.' }
}
$env:MANDALIN_GH = $installGh
while ($true) {
    # Native stderr must not become a terminating PowerShell error before recovery.
    $ErrorActionPreference = 'Continue'
    & $installGh api --hostname github.com "repos/$installRepo" --jq '.full_name' 2>$null
    $accessCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($accessCode -eq 0) { break }
    Write-Host 'Private download access not verified. Check invitation, token/SSO permissions, account or connectivity.'
    $ErrorActionPreference = 'Continue'
    & $installGh api --hostname github.com user --jq '.login' 2>$null
    $ErrorActionPreference = 'Stop'
    Write-Host '1. Retry'; Write-Host '2. Sign in through browser'; Write-Host '3. Switch saved account'; Write-Host '4. Cancel'
    $choice = Read-Host 'Choose [1-4]'
    if ($choice -eq '1') { continue }
    if ($choice -notin @('2', '3')) { throw 'Cancelled.' }
    if ($env:GH_TOKEN -or $env:GITHUB_TOKEN) {
        if ((Read-Host 'Ignore environment token for this installer only? [y/N]') -notmatch '^(y|yes)$') { continue }
        Remove-Item Env:GH_TOKEN, Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
    }
    if ($choice -eq '2') {
        Write-Host 'Open the displayed link, enter the one-time code and authorize. Waiting for GitHub confirmation...'
        $previousPromptSetting = $env:GH_PROMPT_DISABLED
        try { $env:GH_PROMPT_DISABLED = '1'; & $installGh auth login --hostname github.com --web }
        finally { $env:GH_PROMPT_DISABLED = $previousPromptSetting }
    }
    else {
        $status = & $installGh auth status --hostname github.com --json hosts
        if ($LASTEXITCODE -ne 0) { Write-Host 'Could not list accounts; use browser sign-in.'; continue }
        $alternatives = @(($status | ConvertFrom-Json).hosts.'github.com' | Where-Object { -not $_.active } | Select-Object -ExpandProperty login -Unique)
        if (-not $alternatives.Count) { Write-Host 'No other saved account. Use browser sign-in.'; continue }
        $alternatives | ForEach-Object { Write-Host $_ }
        $account = Read-Host 'Exact saved account (blank to go back)'
        if ($alternatives -contains $account) { & $installGh auth switch --hostname github.com --user $account }
    }
}
Write-Host 'Checking published packages...'
$raw = & $installGh api --hostname github.com --paginate --slurp "repos/$installRepo/releases?per_page=100"
if ($LASTEXITCODE -ne 0) { throw 'Could not list releases.' }
$releases = @($raw | ConvertFrom-Json | ForEach-Object { $_ } | ForEach-Object { $_ })
$release = $releases | Where-Object {
    $candidateName = "mandalin-$($_.tag_name -replace '^v','')-win32-$installArch.tar.gz"
    -not $_.draft -and -not $_.prerelease -and $_.tag_name -match '^v\d+\.\d+\.\d+$' -and
    @($_.assets | Where-Object { $_.state -eq 'uploaded' -and $_.name -eq $candidateName }).Count -eq 1 -and
    @($_.assets | Where-Object { $_.state -eq 'uploaded' -and $_.name -eq "$candidateName.sha256" }).Count -eq 1
} | Sort-Object { [version]($_.tag_name -replace '^v','') } -Descending | Select-Object -First 1
if (-not $release) { throw 'No complete prebuilt release for this platform yet. Ask the maintainer to publish one; no source build attempted.' }
$tag = $release.tag_name
$env:MANDALIN_INSTALL_TAG = $tag
$name = "mandalin-$($tag.Substring(1))-win32-$installArch.tar.gz"
$stage = Join-Path $installHome ('downloads/package-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Write-Host "Downloading Mandalin $tag..."
& $installGh release download $tag --repo $installRepo --pattern $name --pattern "$name.sha256" --dir $stage
if ($LASTEXITCODE -ne 0) { throw 'Package download failed.' }
$sums = Get-Content -LiteralPath (Join-Path $stage "$name.sha256") -Raw
$match = [regex]::Matches($sums, ('(?m)^([a-f0-9]{64})\s+' + [regex]::Escape($name) + '\r?$'))
if ($match.Count -ne 1 -or (Get-FileHash -LiteralPath (Join-Path $stage $name) -Algorithm SHA256).Hash -ne $match[0].Groups[1].Value) { throw 'Package checksum mismatch.' }
$destination = Join-Path $installHome ("versions/$tag-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $destination -Force | Out-Null
Write-Host 'Verified. Extracting application...'
& tar.exe -xzf (Join-Path $stage $name) -C $destination
if ($LASTEXITCODE -ne 0) { throw 'Package extraction failed.' }
& (Join-Path $destination 'runtime/node.exe') (Join-Path $destination 'installer/portable.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Mandalin setup did not complete. Previous versions and user data were preserved.' }
} finally {
    # The one-line entry point runs in the user's PowerShell process. A temporary
    # token override must not remove credentials from that terminal afterward.
    $env:GH_TOKEN = $originalGhToken
    $env:GITHUB_TOKEN = $originalGithubToken
}
