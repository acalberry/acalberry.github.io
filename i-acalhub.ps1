<#
.SYNOPSIS
  AcalHub cool custom installer (Windows): package.7z -> dotnet bootstrap -> build from scratch.
.DESCRIPTION
  1. Downloads the whole repo as dist/package.7z from the GitHub release
     (fallback: release .zip, then codeload source zip).
  2. Extracts with 7z (downloads 7zr.exe if missing).
  3. Downloads .NET 8 SDK via dotnet-install.ps1 if `dotnet` is missing.
  4. dotnet restore + dotnet publish src/AcalHub (Release).
  5. Installs to ~/.acalberry/apps/acalhub + shim in ~/.acalberry/bin.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1
  powershell -ExecutionPolicy Bypass -File install.ps1 -Version v0.2.0 -Run
#>
param(
  [string]$Version = "latest",
  [string]$Repo = "acalberry/acalhub",
  [string]$InstallDir = "",
  [switch]$Run,
  [switch]$SkipDotnet
)

$ErrorActionPreference = "Stop"
$DotnetChannel = "8.0"

function Banner($t) { Write-Host ""; Write-Host "== $t ==" -ForegroundColor Cyan }
function Ok($t) { Write-Host "  [OK] $t" -ForegroundColor Green }
function Info($t) { Write-Host "  .. $t" -ForegroundColor Gray }
function Warn($t) { Write-Host "  [!!] $t" -ForegroundColor Yellow }

Write-Host @"
    _                _ _   _       _
   / \   ___ __ _| | | | | |_   _| |__
  / _ \ / __/ _` | | | |_| | | | | '_ \
 / ___ \ (_| (_| | | |  _  | |_| | |_) |
/_/   \_\___\__,_|_|_|_| |_|\__,_|_.__/
"@ -ForegroundColor Magenta
Write-Host "  AcalHub installer (package.7z + dotnet + build from scratch)" -ForegroundColor Gray

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
  $InstallDir = Join-Path $HOME ".acalberry/apps/acalhub"
}
$BinDir = Join-Path $HOME ".acalberry/bin"
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("acalhub-inst-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $TempRoot, $InstallDir, $BinDir | Out-Null

# 1. resolve version
Banner "1/6 resolve version"
$Tag = $Version
if ($Version -eq "latest" -or [string]::IsNullOrWhiteSpace($Version)) {
  try {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -TimeoutSec 20
    $Tag = $rel.tag_name
    Ok "latest = $Tag"
  } catch {
    $Tag = "v0.2.0"
    Warn "API unreachable, using $Tag (override with -Version)"
  }
}
if (-not $Tag.StartsWith("v")) { $Tag = "v" + $Tag }
Info "repo=$Repo tag=$Tag"

# 2. download package.7z (fallbacks: package.zip, codeload)
Banner "2/6 download package"
$Candidates = @(
  "https://github.com/$Repo/releases/download/$Tag/package.7z",
  "https://github.com/$Repo/releases/download/$Tag/package.zip",
  "https://codeload.github.com/$Repo/zip/refs/tags/$Tag",
  "https://codeload.github.com/$Repo/zip/refs/heads/main"
)
$Pkg = Join-Path $TempRoot "package.dl"
$PkgKind = ""
foreach ($u in $Candidates) {
  try {
    Info "GET $u"
    Invoke-WebRequest -Uri $u -OutFile $Pkg -TimeoutSec 120 -UseBasicParsing
    if ((Get-Item $Pkg).Length -lt 1024) { throw "too small, probably an error page" }
    if ($u.EndsWith(".7z")) { $PkgKind = "7z" } else { $PkgKind = "zip" }
    # sniff zip magic PK even if named .7z (codeload fallback)
    $fs = [System.IO.File]::OpenRead($Pkg); $b = New-Object byte[] 2; [void]$fs.Read($b, 0, 2); $fs.Close()
    if ($b[0] -eq 0x50 -and $b[1] -eq 0x4B) { $PkgKind = "zip" }
    if ($b[0] -eq 0x37 -and $b[1] -eq 0x7A) { $PkgKind = "7z" }
    Ok "$PkgKind from $u ($((Get-Item $Pkg).Length) bytes)"
    break
  } catch { Warn "miss: $($_.Exception.Message)" }
}
if ([string]::IsNullOrWhiteSpace($PkgKind)) { throw "download failed: no package.7z/.zip reachable. Check tag or network." }

# 3. extractor (7z if needed)
Banner "3/6 extract package"
$SrcDir = Join-Path $TempRoot "src"
New-Item -ItemType Directory -Force -Path $SrcDir | Out-Null
if ($PkgKind -eq "zip") {
  Expand-Archive -Path $Pkg -DestinationPath $SrcDir -Force
  Ok "unzipped with Expand-Archive"
} else {
  $Seven = $null
  foreach ($c in @("7z", "7zr", "7zz")) { if (Get-Command $c -ErrorAction SilentlyContinue) { $Seven = $c; break } }
  if (-not $Seven) {
    Info "7z missing, fetching 7zr.exe ..."
    $Seven = Join-Path $TempRoot "7zr.exe"
    Invoke-WebRequest -Uri "https://www.7-zip.org/a/7zr.exe" -OutFile $Seven -TimeoutSec 120 -UseBasicParsing
  }
  & $Seven x $Pkg ("-o" + $SrcDir) -y | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "7z extract failed" }
  Ok "extracted with $Seven"
}
$Inner = Get-ChildItem $SrcDir -Directory | Select-Object -First 1
$Root = $SrcDir
if ($Inner -and (Test-Path (Join-Path $Inner.FullName "src/AcalHub/AcalHub.csproj"))) { $Root = $Inner.FullName }
if (-not (Test-Path (Join-Path $Root "src/AcalHub/AcalHub.csproj"))) { throw "package has no src/AcalHub/AcalHub.csproj (root=$Root)" }
Ok "source at $Root"

# 4. dotnet SDK
Banner "4/6 dotnet SDK ($DotnetChannel)"
$DotnetCmd = $null
if (Get-Command dotnet -ErrorAction SilentlyContinue) {
  try {
    $sdks = (& dotnet --list-sdks) -join "`n"
    if ($sdks -match "8\.") { $DotnetCmd = "dotnet"; Ok "found: $((& dotnet --version))" }
    else { Warn "dotnet present but no 8.x SDK" }
  } catch { Warn "dotnet check failed" }
}
$DotnetRoot = Join-Path $HOME ".acalberry/dotnet"
if ((-not $DotnetCmd) -and (-not $SkipDotnet)) {
  Info "installing .NET $DotnetChannel SDK to $DotnetRoot ..."
  $InstPs1 = Join-Path $TempRoot "dotnet-install.ps1"
  Invoke-WebRequest -Uri "https://dot.net/v1/dotnet-install.ps1" -OutFile $InstPs1 -TimeoutSec 120 -UseBasicParsing
  powershell -NoProfile -ExecutionPolicy Bypass -File $InstPs1 -Channel $DotnetChannel -InstallDir $DotnetRoot -NoPath
  $DotnetCmd = Join-Path $DotnetRoot "dotnet.exe"
  $env:PATH = "$DotnetRoot;$env:PATH"
  $env:DOTNET_ROOT = $DotnetRoot
  Ok "dotnet $(& $DotnetCmd --version)"
} elseif ($SkipDotnet) { $DotnetCmd = "dotnet" }
if (-not $DotnetCmd) { throw "no dotnet SDK (re-run without -SkipDotnet)" }

# 5. build from scratch
Banner "5/6 build from scratch (restore + publish)"
& $DotnetCmd --version
& $DotnetCmd restore (Join-Path $Root "src/AcalHub/AcalHub.csproj")
if ($LASTEXITCODE -ne 0) { throw "dotnet restore failed" }
Ok "restore done (packages+deps fetched)"
$Publish = Join-Path $TempRoot "publish"
& $DotnetCmd publish (Join-Path $Root "src/AcalHub/AcalHub.csproj") -c Release -o $Publish
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }
Ok "publish done"

# 6. install + shim
Banner "6/6 install"
Copy-Item (Join-Path $Publish "*") $InstallDir -Recurse -Force
$Shim = Join-Path $BinDir "acalhub.cmd"
$ShimBody = "@echo off`r`n`"$DotnetCmd`" `"$InstallDir\acalhub.dll`" %*`r`n"
Set-Content $Shim $ShimBody -Encoding ASCII
# keep python SDK + examples alongside for app authors
foreach ($extra in @("src/sdk/acalpy.py", "examples/app.json", "README.md")) {
  $s = Join-Path $Root $extra
  if (Test-Path $s) { Copy-Item $s $InstallDir -Force }
}
Ok "installed to $InstallDir"
Ok "shim at $Shim (add $BinDir to PATH)"

Write-Host ""
Write-Host "NEXT:" -ForegroundColor Cyan
Write-Host "  $Shim serve            # hub on http://127.0.0.1:4320/"
Write-Host "  $Shim health           # {ok, apps, version}"
if ($Run) {
  Write-Host ""; Info "starting hub (--Run) ..."
  & $Shim serve
}
Write-Host ""; Write-Host "Done. Registry: ~/.acalberry/acalhub/registry.json" -ForegroundColor Green
