#!/usr/bin/env bash
# Optional – Playwright MCP, a browser for the agents: two servers registered at a
# pinned version, on a persistent Xvfb display of their own (:98). Not part of a
# standard setup. Two parts, each run from this checkout, root first:
#   as root:          optional/playwright-mcp.sh   # Xvfb and the browser's system packages
#   as the box user:  optional/playwright-mcp.sh   # browser, display, registrations
# Run both again to bump the pin.
#
# The pin is the point. @playwright/mcp bundles its own playwright-core, so the
# Chromium build it wants moves with every release – on @latest the server updates
# itself and then cannot find a browser until someone reinstalls one by hand.
# Installing through the server's own install-browser keeps the two in step.
#
# Root installs a fixed package list and never runs node or npx, which would come
# from the box user's home: the agents can write there, and root running it would
# hand them admin rights.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/../scripts/lib.sh"
read_inputs

PLAYWRIGHT_MCP_VERSION=0.0.85
# What `install-deps chromium` installs on Debian 13 for the playwright-core this
# version bundles (1.64.1), xvfb included. Bump it with the version.
APT_PACKAGES=(
  xvfb fonts-noto-color-emoji fonts-unifont libfontconfig1 libfreetype6 xfonts-scalable
  fonts-liberation fonts-ipafont-gothic fonts-wqy-zenhei fonts-tlwg-loma-otf fonts-freefont-ttf
  libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2 libcups2t64
  libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 libnspr4 libnss3 libpango-1.0-0 libx11-6
  libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2
)

if [ "$(id -u)" -eq 0 ]; then
  require_root
  export DEBIAN_FRONTEND=noninteractive
  echo "==> Xvfb and the browser's system packages"
  apt-get update
  apt-get install -y "${APT_PACKAGES[@]}"
  echo "==> Done. Now run this script again as $BOX_USER"
  exit 0
fi
require_box_user
command -v Xvfb >/dev/null || die "Xvfb is missing – run this script as root first"

SPEC="@playwright/mcp@$PLAYWRIGHT_MCP_VERSION"

# npx resolves a package from the working directory before its cache, so run from
# $HOME – the script is meant to work the same from anywhere.
cd "$HOME"

echo "==> Clearing stale npx caches of @playwright/mcp"
# npx keys its cache on the spec string, so every previous pin (and @latest) keeps
# its own copy of the server on disk, each one holding a reference to the Chromium
# build it wanted. Playwright's installer only removes builds nothing references,
# so without this the old builds stay for ever. Every other npx cache belongs to
# another MCP server – leave them alone.
while IFS= read -r -d '' dir; do
  echo "    rm $dir"
  rm -rf "$dir"
done < <(node -e '
  const fs = require("fs"), path = require("path");
  const root = path.join(process.env.HOME, ".npm", "_npx");
  const keep = process.argv[1];
  if (!fs.existsSync(root)) process.exit(0);
  for (const name of fs.readdirSync(root)) {
    const dir = path.join(root, name);
    const manifest = path.join(dir, "package.json");
    if (!fs.existsSync(manifest)) continue;
    let packages;
    try {
      packages = JSON.parse(fs.readFileSync(manifest, "utf8"))?._npx?.packages;
    } catch { continue; }
    if (!Array.isArray(packages)) continue;
    const stale = packages.some(
      (spec) =>
        spec !== keep &&
        (spec === "@playwright/mcp" || spec.startsWith("@playwright/mcp@")),
    );
    if (stale) process.stdout.write(dir + "\0");
  }
' "$SPEC")

echo "==> Installing the browser the pinned server wants"
npx -y "$SPEC" install-browser chromium

echo "==> Starting the servers' display on :98"
# The browser runs headed, because some pages behave differently in a headless
# one. A display of its own keeps it off the 16-pixel :99 that the optional
# terminal route uses as a clipboard holder, where a page gets a 0x0 viewport.
# One persistent display, because an xvfb-run per server is killed at session end
# before its cleanup runs, and leaves its Xvfb behind. :98 because xvfb-run -a
# starts at :99 and never probes below it, and the 10-day /tmp rule deletes a
# long-lived server's lock file, so a number from :99 up would cost every
# xvfb-run -a a try. Comes back at boot because 01-base.sh enables lingering.
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/xvfb-playwright.service" <<'UNIT'
[Unit]
Description=Xvfb on :98 as the display for the Playwright MCP servers

[Service]
ExecStart=/usr/bin/Xvfb :98 -screen 0 1920x1080x24 -nolisten tcp
Restart=on-failure

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now xvfb-playwright.service
for _ in $(seq 20); do
  [[ -S /tmp/.X11-unix/X98 ]] && break
  sleep 0.5
done
[[ -S /tmp/.X11-unix/X98 ]] || {
  echo "xvfb-playwright.service did not bring up :98 – see journalctl --user -u xvfb-playwright" >&2
  exit 1
}

echo "==> Registering the servers at user scope"
claude mcp remove playwright -s user 2>/dev/null || true
# --browser chromium matters: the server defaults to the "chrome" channel and
# looks for Google Chrome at /opt/google/chrome, which is not what we installed.
# --output-dir keeps traces and screenshots out of whatever repo it runs from,
# where they otherwise show up as an untracked .playwright-mcp/ directory.
# -e takes a variadic list, so it goes after the server name, or it swallows it.
# --sandbox because on Linux the server launches Chromium with --no-sandbox unless
# told otherwise, so a renderer bug on any page it loads runs code as the box user
# rather than inside the sandbox. The box supports the sandbox (unprivileged user
# namespaces), so nothing is lost by turning it on.
claude mcp add --scope user playwright -e DISPLAY=:98 \
  -- npx -y "$SPEC" --browser chromium --sandbox \
     --user-data-dir "$HOME/.local/share/playwright-profile" \
     --output-dir "$HOME/.local/share/playwright-mcp-output"

# A second server from the same pin, with its profile kept in memory: no logins,
# and empty again whenever the browser closes. For pages nobody here controls,
# so they never load beside the sessions the persistent profile holds.
claude mcp remove playwright-isolated -s user 2>/dev/null || true
claude mcp add --scope user playwright-isolated -e DISPLAY=:98 \
  -- npx -y "$SPEC" --browser chromium --sandbox --isolated \
     --output-dir "$HOME/.local/share/playwright-mcp-output"

# Read the build back from the installer rather than listing the cache directory,
# which is ambiguous while more than one build is present.
build=$(npx -y "$SPEC" install-browser --dry-run chromium |
  sed -n 's/.*(playwright chromium v\([0-9][0-9]*\)).*/\1/p' | head -1)

echo
echo "Playwright MCP $PLAYWRIGHT_MCP_VERSION, Chromium build ${build:-unknown}"
