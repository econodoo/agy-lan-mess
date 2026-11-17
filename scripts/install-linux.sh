#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_DIR="$REPO_ROOT/apps/mesh_client/build/linux/x64/release/bundle"
SERVER_BIN="$REPO_ROOT/build/agy-mesh-server"

if [ -f "$REPO_ROOT/agy-lan-mesh" ] && [ -d "$REPO_ROOT/data" ]; then
  # Running from an extracted release tarball
  BUNDLE_DIR="$REPO_ROOT"
  SERVER_BIN="$REPO_ROOT/agy-mesh-server"
fi

if [ -f "$SERVER_BIN" ] && [ "$SERVER_BIN" != "$BUNDLE_DIR/agy-mesh-server" ]; then
  cp -f "$SERVER_BIN" "$BUNDLE_DIR/agy-mesh-server"
  chmod +x "$BUNDLE_DIR/agy-mesh-server"
fi

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"

cat > "$HOME/.local/bin/agy-lan-mesh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "--headless" ] || { [ -z "\${DISPLAY:-}" ] && [ -z "\${WAYLAND_DISPLAY:-}" ]; }; then
  shift || true
  exec "$BUNDLE_DIR/agy-mesh-server" "\$@"
fi
exec "$BUNDLE_DIR/agy-lan-mesh" "\$@"
EOF
chmod +x "$HOME/.local/bin/agy-lan-mesh"

cat > "$HOME/.local/share/applications/agy-lan-mesh.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=AGY LAN Mesh
Comment=Control and code across all LAN machines with your central Antigravity Brain
Exec=$BUNDLE_DIR/agy-lan-mesh
Terminal=false
Categories=Development;Utility;Network;
StartupWMClass=com.agylan.mesh_client
EOF

echo "✅ Installed 'agy-lan-mesh' -> $HOME/.local/bin/agy-lan-mesh"
echo "✅ Installed Desktop Launcher -> $HOME/.local/share/applications/agy-lan-mesh.desktop"
