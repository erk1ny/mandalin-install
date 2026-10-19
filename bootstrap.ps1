# Native Windows entry point; also called by bootstrap.sh under Git Bash.
param([switch]$Check)
$ErrorActionPreference = 'Stop'
if ($Check) { Write-Host "Bootstrap syntax/platform check: Windows / $env:PROCESSOR_ARCHITECTURE"; return }
if ([Console]::IsInputRedirected -and $env:MANDALIN_BOOTSTRAP_INTERACTIVE -ne '1') { throw 'Run setup in an interactive terminal.' }
$env:MANDALIN_BOOTSTRAP_INTERACTIVE = '1'
$bootstrapBase = if ($env:MANDALIN_BOOTSTRAP_URL) { $env:MANDALIN_BOOTSTRAP_URL } else { 'https://raw.githubusercontent.com/erk1ny/mandalin-install/main' }
if (-not $bootstrapBase.StartsWith('https://')) { throw 'Bootstrap URL must use HTTPS.' }
$bootstrapHome = if ($env:MANDALIN_HOME) { $env:MANDALIN_HOME } else { Join-Path $env:USERPROFILE '.mandalin' }
function Test-BootstrapNode([string]$NodePath) {
    try {
        & $NodePath -e 'const [a,b]=process.versions.node.match(/[0-9]+/g).map(Number); process.exit(a>22||(a===22&&b>=19)?0:1)' 2>$null
        return $LASTEXITCODE -eq 0
    } catch { return $false }
}
$bootstrapArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } elseif ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') { 'x64' } else { throw 'Only Windows x64 and ARM64 are supported.' }
$bootstrapNodePath = $null
$bootstrapCached = Get-ChildItem -Path (Join-Path $bootstrapHome "runtimes/node-*/node-v*-win-$bootstrapArch/node.exe") -File -ErrorAction SilentlyContinue
foreach ($bootstrapCandidate in $bootstrapCached) {
    $bootstrapNpm = Join-Path $bootstrapCandidate.DirectoryName 'node_modules/npm/bin/npm-cli.js'
    if ((Test-Path -LiteralPath $bootstrapNpm) -and (Test-BootstrapNode $bootstrapCandidate.FullName)) {
        $bootstrapNodePath = $bootstrapCandidate.FullName
        Write-Host "Reusing installed Node runtime: $bootstrapNodePath"
        break
    }
}
if (-not $bootstrapNodePath) {
    $bootstrapNode = Get-Command node -ErrorAction SilentlyContinue
    if ($bootstrapNode -and (Test-BootstrapNode $bootstrapNode.Source)) { $bootstrapNodePath = $bootstrapNode.Source }
}
if (-not $bootstrapNodePath) {
    if ((Read-Host 'Install checksum-verified Node 24 in Mandalin user folder? [y/N]') -notmatch '^(y|yes)$') { throw 'Cancelled; Node was not installed.' }
    $bootstrapStage = Join-Path $bootstrapHome ('runtimes\node-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $bootstrapStage -Force | Out-Null
    $bootstrapSums = (Invoke-WebRequest -UseBasicParsing -Uri 'https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt' -TimeoutSec 120).Content
    $bootstrapMatch = [regex]::Match($bootstrapSums, "(?m)^([a-f0-9]{64})\s+(node-(v24\.\d+\.\d+)-win-$bootstrapArch\.zip)\s*$")
    if (-not $bootstrapMatch.Success) { throw 'No matching Node archive.' }
    $bootstrapArchive = Join-Path $bootstrapStage $bootstrapMatch.Groups[2].Value
    Write-Host 'Downloading Node 24...'
    Invoke-WebRequest -UseBasicParsing -Uri ('https://nodejs.org/dist/' + $bootstrapMatch.Groups[3].Value + '/' + $bootstrapMatch.Groups[2].Value) -OutFile $bootstrapArchive -TimeoutSec 600
    Write-Host 'Verifying Node download...'
    if ((Get-FileHash -LiteralPath $bootstrapArchive -Algorithm SHA256).Hash -ne $bootstrapMatch.Groups[1].Value) { throw 'Node checksum mismatch; refusing to extract or execute.' }
    Write-Host 'Extracting Node runtime...'
    Expand-Archive -LiteralPath $bootstrapArchive -DestinationPath $bootstrapStage
    $bootstrapNodePath = Join-Path (Join-Path $bootstrapStage ([IO.Path]::GetFileNameWithoutExtension($bootstrapArchive))) 'node.exe'
    if (-not (Test-BootstrapNode $bootstrapNodePath)) { throw "Downloaded Node cannot run on this system: $bootstrapNodePath" }
}
$bootstrapWork = Join-Path ([IO.Path]::GetTempPath()) ('mandalin-bootstrap-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $bootstrapWork | Out-Null
Write-Host 'Downloading guided installer...'
Invoke-WebRequest -UseBasicParsing -Uri "$bootstrapBase/bootstrap.mjs" -OutFile (Join-Path $bootstrapWork 'bootstrap.mjs') -TimeoutSec 120
Write-Host 'Starting guided setup...'
& $bootstrapNodePath (Join-Path $bootstrapWork 'bootstrap.mjs')
if ($LASTEXITCODE -ne 0) { throw "Mandalin setup failed (exit $LASTEXITCODE). No research data was removed." }
