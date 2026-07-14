# OpenMNK agent environment bootstrap — Windows
# Installs the pinned toolchain agents rely on: VC++ runtime, Node.js, Google Workspace CLI,
# playwright-cli (+ browser), Python, ctx7. Idempotent — safe to re-run; finished stages skip.
#
# Run:  curl.exe -fsSL https://raw.githubusercontent.com/Emericen/openmnk-releases/main/setup/windows.ps1 -o "$env:TEMP\openmnk-setup.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\openmnk-setup.ps1"
#
# Output contract (for agents): every line is logged to %TEMP%\openmnk-setup.log.
# The FINAL line is exactly "SETUP-OK" or "SETUP-FAIL:<stage>". On failure, read the log.
#
# Windows PowerShell 5.1 compatible. Downloads use curl.exe (ships with Windows 10+);
# Invoke-WebRequest is ~100x slower on big files — never used here.

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$NODE_VERSION = "24.18.0"
$GWS_VERSION = "0.22.5"
$PYTHON_VERSION = "3.12.10"

$Root = "$env:LOCALAPPDATA\openmnk\tools"
$NodeDir = "$Root\node"
$LogFile = "$env:TEMP\openmnk-setup.log"

function Log($m) {
  $line = "{0} {1}" -f (Get-Date -Format "HH:mm:ss"), $m
  Add-Content -Path $LogFile -Value $line
  Write-Output $line
}
function Fail($stage, $err) {
  Log ("ERROR at {0}: {1}" -f $stage, $err)
  Write-Output ("SETUP-FAIL:{0} (details: {1})" -f $stage, $LogFile)
  exit 1
}
function Fetch($url, $out, $stage) {
  Log ("download {0}" -f $url)
  & "$env:SystemRoot\System32\curl.exe" -fsSL --retry 3 --retry-delay 2 -o $out $url
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) { Fail $stage "download failed: $url (curl exit $LASTEXITCODE)" }
}

New-Item -ItemType Directory -Force $Root | Out-Null
Log "=== OpenMNK bootstrap start (node=$NODE_VERSION gws=$GWS_VERSION python=$PYTHON_VERSION) ==="

# ── stage: vcruntime ─────────────────────────────────────────────────────────
# @googleworkspace/cli ships a native module that needs the VC++ runtime; clean
# Windows 11 does not have it. Installer requires elevation — this is the one
# stage that may show a Windows permission prompt.
try {
  if (Test-Path "$env:SystemRoot\System32\vcruntime140.dll") {
    Log "vcruntime: already present, skip"
  } else {
    $vc = "$env:TEMP\vc_redist.x64.exe"
    Fetch "https://aka.ms/vs/17/release/vc_redist.x64.exe" $vc "vcruntime"
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
      $p = Start-Process $vc -ArgumentList "/install", "/quiet", "/norestart" -Wait -PassThru
    } else {
      Log "vcruntime: requesting elevation (approve the Windows prompt)"
      $p = Start-Process $vc -ArgumentList "/install", "/quiet", "/norestart" -Verb RunAs -Wait -PassThru
    }
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { Fail "vcruntime" ("installer exit {0}" -f $p.ExitCode) }
    if (-not (Test-Path "$env:SystemRoot\System32\vcruntime140.dll")) { Fail "vcruntime" "dll still missing after install" }
    Log "vcruntime: installed"
  }
} catch { Fail "vcruntime" $_.Exception.Message }

# ── stage: node ──────────────────────────────────────────────────────────────
try {
  if ((Test-Path "$NodeDir\node.exe") -and ((& "$NodeDir\node.exe" --version) -eq "v$NODE_VERSION")) {
    Log "node: v$NODE_VERSION already installed, skip"
  } else {
    $zip = "$env:TEMP\node-v$NODE_VERSION.zip"
    Fetch "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-win-x64.zip" $zip "node"
    if (Test-Path $NodeDir) { Remove-Item $NodeDir -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath "$Root\_node_tmp" -Force
    Move-Item "$Root\_node_tmp\node-v$NODE_VERSION-win-x64" $NodeDir
    Remove-Item "$Root\_node_tmp" -Recurse -Force -ErrorAction SilentlyContinue
    Log ("node: installed {0}" -f (& "$NodeDir\node.exe" --version))
  }
  # PATH: current session + persistent user PATH
  $env:Path = "$NodeDir;" + $env:Path
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if ($userPath -notlike "*$NodeDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$NodeDir;$userPath", "User")
    Log "node: added to user PATH"
  }
} catch { Fail "node" $_.Exception.Message }

# ── stage: npm-packages ──────────────────────────────────────────────────────
# Global CLIs agents use. .ps1 shims break under default execution policy —
# agents should invoke the .cmd shims; we also allow per-user scripts.
try {
  try { Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force -ErrorAction Stop } catch {}
  # native tools write warnings to stderr; run via cmd with merged streams so PS 5.1
  # doesn't promote npm warnings to terminating errors
  $out = cmd /c "`"$NodeDir\npm.cmd`" install -g --no-fund --no-audit @googleworkspace/cli@$GWS_VERSION @playwright/cli@latest ctx7@latest 2>&1"
  $out | ForEach-Object { Add-Content $LogFile $_ }
  if ($LASTEXITCODE -ne 0) { Fail "npm-packages" "npm install -g exit $LASTEXITCODE" }
  Log "npm-packages: gws, playwright-cli, ctx7 installed"
} catch { Fail "npm-packages" $_.Exception.Message }

# ── stage: playwright-browser ────────────────────────────────────────────────
try {
  $pwc = "$NodeDir\playwright-cli.cmd"
  if (-not (Test-Path $pwc)) { Fail "playwright-browser" "playwright-cli.cmd not found in $NodeDir" }
  $out = cmd /c "`"$pwc`" install-browser 2>&1"
  $out | Select-Object -Last 5 | ForEach-Object { Add-Content $LogFile $_ }
  if ($LASTEXITCODE -ne 0) { Fail "playwright-browser" "install-browser exit $LASTEXITCODE" }
  Log "playwright-browser: installed"
} catch { Fail "playwright-browser" $_.Exception.Message }

# ── stage: python ────────────────────────────────────────────────────────────
# Per-user install, no elevation needed.
try {
  $pyExe = "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
  if (Test-Path $pyExe) {
    Log ("python: already installed ({0}), skip" -f (& $pyExe --version))
  } else {
    $pyInstaller = "$env:TEMP\python-$PYTHON_VERSION.exe"
    Fetch "https://www.python.org/ftp/python/$PYTHON_VERSION/python-$PYTHON_VERSION-amd64.exe" $pyInstaller "python"
    $p = Start-Process $pyInstaller -ArgumentList "/quiet", "InstallAllUsers=0", "PrependPath=1", "Include_test=0" -Wait -PassThru
    if ($p.ExitCode -ne 0) { Fail "python" ("installer exit {0}" -f $p.ExitCode) }
    if (-not (Test-Path $pyExe)) { Fail "python" "python.exe missing after install" }
    Log ("python: installed {0}" -f (& $pyExe --version))
  }
} catch { Fail "python" $_.Exception.Message }

# ── verify ───────────────────────────────────────────────────────────────────
try {
  $nodeV = cmd /c "`"$NodeDir\node.exe`" --version 2>&1"
  $npmV = (cmd /c "`"$NodeDir\npm.cmd`" --version 2>&1") | Select-Object -Last 1
  $gwsV = (cmd /c "`"$NodeDir\node.exe`" `"$NodeDir\node_modules\@googleworkspace\cli\run.js`" --version 2>&1") | Where-Object { $_ -match "\d+\.\d+" } | Select-Object -First 1
  $pwV = (cmd /c "`"$NodeDir\playwright-cli.cmd`" --version 2>&1") | Select-Object -Last 1
  $pyV = cmd /c "`"$env:LOCALAPPDATA\Programs\Python\Python312\python.exe`" --version 2>&1"
  Log "=== versions: node=$nodeV npm=$npmV gws=$gwsV playwright-cli=$pwV python=$pyV ==="
} catch { Fail "verify" $_.Exception.Message }

Write-Output "SETUP-OK"
