#!/usr/bin/env bash
# AcalHub cool custom installer (Linux): package.7z -> dotnet bootstrap -> build from scratch.
# Usage: bash install.sh [--version v0.2.0] [--run] [--repo acalberry/acalhub]
set -euo pipefail
REPO="acalberry/acalhub"
VER="latest"
RUN=0
INSTALL_DIR="$HOME/.acalberry/apps/acalhub"
BIN_DIR="$HOME/.acalberry/bin"
DOTNET_CHANNEL="8.0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VER="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --run) RUN=1; shift;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done
say(){ echo "== $1 =="; }
ok(){ echo "  [OK] $1"; }
info(){ echo "  .. $1"; }
warn(){ echo "  [!!] $1"; }
cat <<'LOGO'
    _                _ _   _       _
   / \   ___ __ _| | | | | |_   _| |__
  / _ \ / __/ _` | | | |_| | | | | '_ \
 / ___ \ (_| (_| | | |  _  | |_| | |_) |
/_/   \_\___\__,_|_|_|_| |_|\__,_|_.__/
LOGO
echo "  AcalHub installer (package.7z + dotnet + build from scratch)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$INSTALL_DIR" "$BIN_DIR"

say "1/6 resolve version"
TAG="$VER"
if [[ "$VER" == "latest" ]]; then
  if TAG="$(curl -fsSL --max-time 20 "https://api.github.com/repos/$REPO/releases/latest" | grep -m1 '"tag_name"' | cut -d'"' -f4)" && [[ -n "$TAG" ]]; then
    ok "latest = $TAG"
  else
    TAG="v0.2.0"; warn "API unreachable, using $TAG"
  fi
fi
[[ "$TAG" == v* ]] || TAG="v$TAG"
info "repo=$REPO tag=$TAG"

say "2/6 download package"
PKG="$TMP/package.dl"; KIND=""
for u in "https://github.com/$REPO/releases/download/$TAG/package.7z" \
         "https://github.com/$REPO/releases/download/$TAG/package.zip" \
         "https://codeload.github.com/$REPO/zip/refs/tags/$TAG" \
         "https://codeload.github.com/$REPO/zip/refs/heads/main"; do
  info "GET $u"
  if curl -fSL --max-time 120 "$u" -o "$PKG" && [[ $(stat -c%s "$PKG" 2>/dev/null || stat -f%z "$PKG") -gt 1024 ]]; then
    if head -c2 "$PKG" | grep -q "PK"; then KIND="zip"; else KIND="7z"; fi
    [[ "$u" == *.7z && "$KIND" != "zip" ]] && KIND="7z"
    ok "$KIND from $u"; break
  else warn "miss"; fi
done
[[ -n "$KIND" ]] || { echo "download failed"; exit 1; }

say "3/6 extract package"
SRC="$TMP/src"; mkdir -p "$SRC"
if [[ "$KIND" == "zip" ]]; then
  (command -v unzip >/dev/null && unzip -q "$PKG" -d "$SRC") || python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$PKG" "$SRC"
  ok "unzipped"
else
  if command -v 7z >/dev/null; then SZ=7z
  elif command -v 7zz >/dev/null; then SZ=7zz
  else warn "7z missing, trying python fallback"; SZ=""
  fi
  if [[ -n "${SZ:-}" ]]; then $SZ x "$PKG" -o"$SRC" -y >/dev/null; ok "extracted with $SZ"
  else python3 -c "import shutil; shutil.unpack_archive('$PKG','$SRC')" && ok "extracted (fallback)"; fi
fi
ROOT="$SRC"
INNER="$(find "$SRC" -maxdepth 2 -name AcalHub.csproj | head -n1 || true)"
[[ -n "$INNER" ]] && ROOT="$(dirname "$(dirname "$INNER")")"
[[ -f "$ROOT/src/AcalHub/AcalHub.csproj" ]] || { echo "no src/AcalHub/AcalHub.csproj in package"; exit 1; }
ok "source at $ROOT"

say "4/6 dotnet SDK ($DOTNET_CHANNEL)"
DOTNET="dotnet"
if ! (command -v dotnet >/dev/null && dotnet --list-sdks 2>/dev/null | grep -q "8\."); then
  info "installing .NET $DOTNET_CHANNEL to $HOME/.acalberry/dotnet ..."
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$TMP/dotnet-install.sh"
  bash "$TMP/dotnet-install.sh" --channel "$DOTNET_CHANNEL" --install-dir "$HOME/.acalberry/dotnet"
  export DOTNET_ROOT="$HOME/.acalberry/dotnet"; export PATH="$DOTNET_ROOT:$PATH"
  DOTNET="$DOTNET_ROOT/dotnet"
fi
ok "dotnet $($DOTNET --version)"

say "5/6 build from scratch (restore + publish)"
$DOTNET restore "$ROOT/src/AcalHub/AcalHub.csproj"
ok "restore done (packages+deps fetched)"
$DOTNET publish "$ROOT/src/AcalHub/AcalHub.csproj" -c Release -o "$TMP/publish"
ok "publish done"

say "6/6 install"
cp -r "$TMP/publish/"* "$INSTALL_DIR"/
printf '#!/usr/bin/env bash\nexec "%s" "%s/acalhub.dll" "$@"\n' "$DOTNET" "$INSTALL_DIR" > "$BIN_DIR/acalhub"
chmod +x "$BIN_DIR/acalhub"
cp "$ROOT/src/sdk/acalpy.py" "$INSTALL_DIR"/ 2>/dev/null || true
ok "installed to $INSTALL_DIR"
ok "shim at $BIN_DIR/acalhub (add $BIN_DIR to PATH)"
echo ""
echo "NEXT:"
echo "  $BIN_DIR/acalhub serve     # hub on http://127.0.0.1:4320/"
echo "  $BIN_DIR/acalhub health"
[[ "$RUN" == "1" ]] && exec "$BIN_DIR/acalhub" serve
echo "Done. Registry: ~/.acalberry/acalhub/registry.json"
