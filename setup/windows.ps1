# OpenMNK agent environment bootstrap — Windows
# Installs the pinned toolchain agents rely on: VC++ runtime, Node.js, Google Workspace CLI,
# playwright-cli (+ browser), Python, uv, ctx7. Idempotent — safe to re-run; finished stages skip.
#
# Run:  curl.exe -fsSL https://raw.githubusercontent.com/Emericen/openmnk-releases/main/setup/windows.ps1 -o "$env:TEMP\openmnk-setup.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\openmnk-setup.ps1"
#
# Stage selection (default = everything):
#   -Skip gws            install everything except gws
#   -Skip "gws,python"   comma list
#   -Only "node,uv"      install ONLY these (plus auto-added prerequisites:
#                        npm CLIs pull in node; gws pulls in vcruntime)
# Stages: vcruntime, node, gws, playwright, ctx7, python, uv
#
# Output contract (for agents): every line is logged to %TEMP%\openmnk-setup.log.
# The FINAL line is exactly "SETUP-OK" or "SETUP-FAIL:<stage>". On failure, read the log.
#
# Windows PowerShell 5.1 compatible. Downloads use curl.exe (ships with Windows 10+);
# Invoke-WebRequest is ~100x slower on big files — never used here.
param(
  [string]$Only = "",
  [string]$Skip = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$NODE_VERSION = "24.18.0"
$GWS_VERSION = "0.22.5"
$PYTHON_VERSION = "3.12.10"
$PLAYWRIGHT_CLI_VERSION = "0.1.17"
$CTX7_VERSION = "0.5.4"
$UV_VERSION = "0.11.30"

# ── stage selection ──────────────────────────────────────────────────────────
$AllStages = @("vcruntime", "node", "gws", "playwright", "ctx7", "python", "uv")
if ($Only -ne "" -and $Skip -ne "") {
  Write-Output "SETUP-FAIL:args (-Only and -Skip are mutually exclusive)"
  exit 1
}
if ($Only -ne "") {
  $Selected = @($Only.Split(",") | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
} else {
  $SkipList = @($Skip.Split(",") | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
  $Selected = @($AllStages | Where-Object { $SkipList -notcontains $_ })
}
$BadStages = @($Selected | Where-Object { $AllStages -notcontains $_ })
if ($BadStages.Count -gt 0) {
  Write-Output ("SETUP-FAIL:args (unknown stage(s): {0}; valid: {1})" -f ($BadStages -join ","), ($AllStages -join ","))
  exit 1
}
function Want($s) { return $Selected -contains $s }
# prerequisites: npm-installed CLIs need node; gws's native module needs the VC++ runtime
if (((Want "gws") -or (Want "playwright") -or (Want "ctx7")) -and -not (Want "node")) { $Selected += "node" }
if ((Want "gws") -and -not (Want "vcruntime")) { $Selected += "vcruntime" }

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
Log ("=== OpenMNK bootstrap start (stages: {0}) ===" -f (($AllStages | Where-Object { Want $_ }) -join ", "))

# ── stage: vcruntime ─────────────────────────────────────────────────────────
# @googleworkspace/cli ships a native module that needs the VC++ runtime; clean
# Windows 11 does not have it. Installer requires elevation — this is the one
# stage that may show a Windows permission prompt.
if (Want "vcruntime") {
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
} else { Log "vcruntime: skipped (not selected)" }

# ── stage: node ──────────────────────────────────────────────────────────────
if (Want "node") {
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
} else { Log "node: skipped (not selected)" }

# ── stage: npm-packages (gws / playwright / ctx7) ────────────────────────────
# Global CLIs agents use. .ps1 shims break under default execution policy —
# agents should invoke the .cmd shims; we also allow per-user scripts.
$NpmPkgs = @()
if (Want "gws") { $NpmPkgs += "@googleworkspace/cli@$GWS_VERSION" }
if (Want "playwright") { $NpmPkgs += "@playwright/cli@$PLAYWRIGHT_CLI_VERSION" }
if (Want "ctx7") { $NpmPkgs += "ctx7@$CTX7_VERSION" }
if ($NpmPkgs.Count -gt 0) {
try {
  try { Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force -ErrorAction Stop } catch {}
  # native tools write warnings to stderr; run via cmd with merged streams so PS 5.1
  # doesn't promote npm warnings to terminating errors
  $out = cmd /c "`"$NodeDir\npm.cmd`" install -g --no-fund --no-audit $($NpmPkgs -join ' ') 2>&1"
  $out | ForEach-Object { Add-Content $LogFile $_ }
  if ($LASTEXITCODE -ne 0) { Fail "npm-packages" "npm install -g exit $LASTEXITCODE" }
  Log ("npm-packages: installed {0}" -f ($NpmPkgs -join ", "))
} catch { Fail "npm-packages" $_.Exception.Message }
} else { Log "npm-packages: skipped (none selected)" }

# ── stage: playwright-browser ────────────────────────────────────────────────
if (Want "playwright") {
try {
  $pwc = "$NodeDir\playwright-cli.cmd"
  if (-not (Test-Path $pwc)) { Fail "playwright-browser" "playwright-cli.cmd not found in $NodeDir" }
  $out = cmd /c "`"$pwc`" install-browser 2>&1"
  $out | Select-Object -Last 5 | ForEach-Object { Add-Content $LogFile $_ }
  if ($LASTEXITCODE -ne 0) { Fail "playwright-browser" "install-browser exit $LASTEXITCODE" }
  Log "playwright-browser: installed"
} catch { Fail "playwright-browser" $_.Exception.Message }
} else { Log "playwright-browser: skipped (not selected)" }

# ── stage: python ────────────────────────────────────────────────────────────
# Per-user install, no elevation needed.
if (Want "python") {
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
} else { Log "python: skipped (not selected)" }

# ── stage: uv ────────────────────────────────────────────────────────────────
# Astral's pinned installer; per-user, lands in %USERPROFILE%\.local\bin.
if (Want "uv") {
try {
  $UvBin = "$env:USERPROFILE\.local\bin"
  $uvExe = "$UvBin\uv.exe"
  $cur = ""
  if (Test-Path $uvExe) { $cur = (cmd /c "`"$uvExe`" --version 2>&1") | Select-Object -First 1 }
  if ("$cur" -match [regex]::Escape($UV_VERSION)) {
    Log "uv: $UV_VERSION already installed, skip"
  } else {
    $uvScript = "$env:TEMP\uv-install.ps1"
    Fetch "https://astral.sh/uv/$UV_VERSION/install.ps1" $uvScript "uv"
    # Pin the install dir explicitly. The installer otherwise honors XDG_* env vars, and shells
    # spawned by the OpenMNK app inherit XDG roots pinned to the app's containment folder —
    # uv.exe would land in AppData\Roaming\openmnk\... and the check below would fail.
    $out = cmd /c "set UV_INSTALL_DIR=$UvBin&& set UV_NO_MODIFY_PATH=1&& powershell -NoProfile -ExecutionPolicy Bypass -File `"$uvScript`" 2>&1"
    $out | ForEach-Object { Add-Content $LogFile $_ }
    if (-not (Test-Path $uvExe)) { Fail "uv" "uv.exe missing after install" }
    Log ("uv: installed {0}" -f ((cmd /c "`"$uvExe`" --version 2>&1") | Select-Object -First 1))
  }
  $env:Path = "$UvBin;" + $env:Path
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if ($userPath -notlike "*$UvBin*") {
    [Environment]::SetEnvironmentVariable("Path", "$UvBin;$userPath", "User")
    Log "uv: added to user PATH"
  }
} catch { Fail "uv" $_.Exception.Message }
} else { Log "uv: skipped (not selected)" }

# ── verify ───────────────────────────────────────────────────────────────────
try {
  $versions = @()
  $paths = @()
  if (Want "node") {
    $versions += ("node=" + (cmd /c "`"$NodeDir\node.exe`" --version 2>&1"))
    $versions += ("npm=" + ((cmd /c "`"$NodeDir\npm.cmd`" --version 2>&1") | Select-Object -Last 1))
    $paths += "node=$NodeDir\node.exe"; $paths += "npm=$NodeDir\npm.cmd"
  }
  if (Want "gws") {
    $versions += ("gws=" + ((cmd /c "`"$NodeDir\node.exe`" `"$NodeDir\node_modules\@googleworkspace\cli\run.js`" --version 2>&1") | Where-Object { $_ -match "\d+\.\d+" } | Select-Object -First 1))
    $paths += "gws=$NodeDir\gws.cmd"
  }
  if (Want "playwright") {
    $versions += ("playwright-cli=" + ((cmd /c "`"$NodeDir\playwright-cli.cmd`" --version 2>&1") | Select-Object -Last 1))
    $paths += "playwright-cli=$NodeDir\playwright-cli.cmd"
  }
  if (Want "python") {
    $versions += ("python=" + (cmd /c "`"$env:LOCALAPPDATA\Programs\Python\Python312\python.exe`" --version 2>&1"))
    $paths += "python=$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
  }
  if (Want "uv") {
    $versions += ("uv=" + ((cmd /c "`"$env:USERPROFILE\.local\bin\uv.exe`" --version 2>&1") | Select-Object -First 1))
    $paths += "uv=$env:USERPROFILE\.local\bin\uv.exe"
  }
  Log ("=== versions: {0} ===" -f ($versions -join " "))
  # Shells spawned by an app that was already running BEFORE this script ran inherit a stale
  # PATH. Print absolute paths so agents can keep working without an app restart.
  Log ("=== paths: {0} ===" -f ($paths -join " "))
  Log "note: if a tool is 'not recognized' in this session, use the absolute paths above (or restart the app); new shells opened after app restart will have them on PATH"
} catch { Fail "verify" $_.Exception.Message }

Write-Output "SETUP-OK"
