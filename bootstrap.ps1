# Native Windows entry point; also called by bootstrap.sh under Git Bash.
param([switch]$Check)
$ErrorActionPreference = 'Stop'
if ($Check) { Write-Host "Bootstrap syntax/platform check: Windows / $env:PROCESSOR_ARCHITECTURE"; return }
if ([Console]::IsInputRedirected -and $env:MANDALIN_BOOTSTRAP_INTERACTIVE -ne '1') { throw 'Run setup in an interactive terminal.' }
$env:MANDALIN_BOOTSTRAP_INTERACTIVE = '1'
$bootstrapBase = if ($env:MANDALIN_BOOTSTRAP_URL) { $env:MANDALIN_BOOTSTRAP_URL } else { 'https://raw.githubusercontent.com/erk1ny/mandalin-install/main' }
if (-not $bootstrapBase.StartsWith('https://')) { throw 'Bootstrap URL must use HTTPS.' }
$bootstrapHome = if ($env:MANDALIN_HOME) { $env:MANDALIN_HOME } else { Join-Path $env:USERPROFILE '.mandalin' }
$bootstrapNode = Get-Command node -ErrorAction SilentlyContinue
$bootstrapNodeOk = $false
if ($bootstrapNode) {
    & $bootstrapNode.Source -e 'const [a,b]=process.versions.node.match(/[0-9]+/g).map(Number); process.exit(a>22||(a===22&&b>=19)?0:1)'
    $bootstrapNodeOk = $LASTEXITCODE -eq 0
}
if ($bootstrapNodeOk) {
    $bootstrapNodePath = $bootstrapNode.Source
} else {
    if ((Read-Host 'Install checksum-verified Node 24 in Mandalin user folder? [y/N]') -notmatch '^(y|yes)$') { throw 'Cancelled; Node was not installed.' }
    $bootstrapArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } elseif ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') { 'x64' } else { throw 'Only Windows x64 and ARM64 are supported.' }
    $bootstrapStage = Join-Path $bootstrapHome ('runtimes\node-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $bootstrapStage -Force | Out-Null
    $bootstrapSums = (Invoke-WebRequest -UseBasicParsing -Uri 'https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt' -TimeoutSec 120).Content
    $bootstrapMatch = [regex]::Match($bootstrapSums, "(?m)^([a-f0-9]{64})\s+(node-(v24\.\d+\.\d+)-win-$bootstrapArch\.zip)\s*$")
    if (-not $bootstrapMatch.Success) { throw 'No matching Node archive.' }
    $bootstrapArchive = Join-Path $bootstrapStage $bootstrapMatch.Groups[2].Value
    Write-Host 'Downloading Node 24...'
    Invoke-WebRequest -UseBasicParsing -Uri ('https://nodejs.org/dist/' + $bootstrapMatch.Groups[3].Value + '/' + $bootstrapMatch.Groups[2].Value) -OutFile $bootstrapArchive -TimeoutSec 600
    if ((Get-FileHash -LiteralPath $bootstrapArchive -Algorithm SHA256).Hash -ne $bootstrapMatch.Groups[1].Value) { throw 'Node checksum mismatch; refusing to extract or execute.' }
    Expand-Archive -LiteralPath $bootstrapArchive -DestinationPath $bootstrapStage
    $bootstrapNodePath = Join-Path (Join-Path $bootstrapStage ([IO.Path]::GetFileNameWithoutExtension($bootstrapArchive))) 'node.exe'
}
$bootstrapWork = Join-Path ([IO.Path]::GetTempPath()) ('mandalin-bootstrap-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $bootstrapWork | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri "$bootstrapBase/bootstrap.mjs" -OutFile (Join-Path $bootstrapWork 'bootstrap.mjs') -TimeoutSec 120
& $bootstrapNodePath (Join-Path $bootstrapWork 'bootstrap.mjs')
if ($LASTEXITCODE -ne 0) { throw "Mandalin setup failed (exit $LASTEXITCODE). No research data was removed." }
