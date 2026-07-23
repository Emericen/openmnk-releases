# OpenMNK Tax Analyst environment — Windows
# Installs exactly what the Tax Analyst agent needs, nothing else:
#   - Python 3.12 (per-user, no elevation)
#   - pinned document libraries: pypdfium2, pypdf, rapidocr, openpyxl, python-docx
#   - the `digitize` command (intake folder -> machine-readable _ocr twin)
# Idempotent — safe to re-run; finished steps skip.
#
# Run:  curl.exe -fsSL https://raw.githubusercontent.com/Emericen/openmnk-releases/main/tax-analyst/windows-setup.ps1 -o "$env:TEMP\tax-setup.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\tax-setup.ps1"
#
# Output contract (for agents): every line is logged to %TEMP%\tax-analyst-setup.log.
# The FINAL line is exactly "SETUP-OK" or "SETUP-FAIL:<stage>". On failure, read the log.
#
# Windows PowerShell 5.1 compatible. Downloads use curl.exe (ships with Windows 10+).

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$PYTHON_VERSION = "3.12.10"
$DOC_LIBS = "pypdfium2==5.12.1 pypdf==6.14.2 rapidocr-onnxruntime==1.4.4 openpyxl==3.1.5 python-docx==1.2.0"
$DIGITIZE_URL = "https://raw.githubusercontent.com/Emericen/openmnk-releases/main/tax-analyst/digitize.py"

$Root = "$env:LOCALAPPDATA\openmnk\tax-analyst"
$BinDir = "$env:USERPROFILE\.local\bin"
$PyExe = "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
$LogFile = "$env:TEMP\tax-analyst-setup.log"

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
New-Item -ItemType Directory -Force $BinDir | Out-Null
Log "=== Tax Analyst setup start (python=$PYTHON_VERSION) ==="

# ── step: python ─────────────────────────────────────────────────────────────
try {
  if (Test-Path $PyExe) {
    Log ("python: already installed ({0}), skip" -f (& $PyExe --version))
  } else {
    $installer = "$env:TEMP\python-$PYTHON_VERSION.exe"
    Fetch "https://www.python.org/ftp/python/$PYTHON_VERSION/python-$PYTHON_VERSION-amd64.exe" $installer "python"
    $p = Start-Process $installer -ArgumentList "/quiet", "InstallAllUsers=0", "PrependPath=1", "Include_test=0" -Wait -PassThru
    if ($p.ExitCode -ne 0) { Fail "python" ("installer exit {0}" -f $p.ExitCode) }
    if (-not (Test-Path $PyExe)) { Fail "python" "python.exe missing after install" }
    Log ("python: installed {0}" -f (& $PyExe --version))
  }
} catch { Fail "python" $_.Exception.Message }

# ── step: document libraries ─────────────────────────────────────────────────
try {
  $out = cmd /c "`"$PyExe`" -m pip install --quiet --disable-pip-version-check $DOC_LIBS 2>&1"
  $out | ForEach-Object { Add-Content $LogFile $_ }
  if ($LASTEXITCODE -ne 0) { Fail "doc-libs" "pip install exit $LASTEXITCODE" }
  $out = cmd /c "`"$PyExe`" -c `"import pypdfium2, pypdf, rapidocr_onnxruntime, openpyxl, docx`" 2>&1"
  $out | ForEach-Object { Add-Content $LogFile $_ }
  if ($LASTEXITCODE -ne 0) { Fail "doc-libs" "libraries not importable after install" }
  Log "doc-libs: installed and importable"
} catch { Fail "doc-libs" $_.Exception.Message }

# ── step: digitize command ───────────────────────────────────────────────────
try {
  Fetch $DIGITIZE_URL "$Root\digitize.py" "digitize"
  Set-Content -Path "$BinDir\digitize.cmd" -Value "@`"$PyExe`" `"$Root\digitize.py`" %*"
  $env:Path = "$BinDir;" + $env:Path
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if ($userPath -notlike "*$BinDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$BinDir;$userPath", "User")
    Log "digitize: added $BinDir to user PATH"
  }
  Log "digitize: installed at $BinDir\digitize.cmd"
} catch { Fail "digitize" $_.Exception.Message }

# ── verify ───────────────────────────────────────────────────────────────────
try {
  $pyV = cmd /c "`"$PyExe`" --version 2>&1"
  Log "=== versions: python=$pyV libs=$DOC_LIBS ==="
  # Shells spawned by an app that was already running BEFORE this script inherit a stale
  # PATH. Print absolute paths so agents can keep working without an app restart.
  Log "=== paths: python=$PyExe digitize=$BinDir\digitize.cmd ==="
  Log "note: if a tool is 'not recognized' in this session, use the absolute paths above"
} catch { Fail "verify" $_.Exception.Message }

Write-Output "SETUP-OK"
