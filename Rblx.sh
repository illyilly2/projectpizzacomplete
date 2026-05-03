#!/bin/bash
# ============================================================
#  Project Pizza — UniversalClient Codespaces Build Script
#  Run this inside a GitHub Codespace opened on your fork
#  of https://github.com/lmaobamar/projectpizzacomplete
#
#  Usage:
#    chmod +x build-client.sh
#    ./build-client.sh
#
#  What this does:
#    1. Installs all system dependencies
#    2. Installs and activates EMSDK (Emscripten)
#    3. Installs vcpkg
#    4. Validates FMOD HTML5 SDK (you must commit it to your fork first)
#    5. Creates empty .assets folders if missing
#    6. Configures with cmake (runs vcpkg — takes 40-60 min first time)
#    7. Builds UniversalClient
#    8. Patches the HTML shell with Module.arguments
#    9. Sets up the Node.js API server
#    10. Starts everything and prints the URL to open
# ============================================================

set -e  # exit on any error

# ────────────────────────────────────────────────────────────
# ANSI colors
# ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log()     { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $1${NC}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}\n"; }

# ────────────────────────────────────────────────────────────
# CONFIG — edit these if needed
# ────────────────────────────────────────────────────────────
REPO_DIR="/workspaces/projectpizzacomplete"
BUILD_DIR="$REPO_DIR/build/emscripten-release"
TOOLS_DIR="$REPO_DIR/.build-tools"
EMSDK_DIR="$TOOLS_DIR/emsdk"
VCPKG_DIR="$TOOLS_DIR/vcpkg"
FMOD_HTML5_ROOT="$REPO_DIR/fmod-html5"   # where you committed FMOD HTML5 files
SERVER_DIR="$REPO_DIR/.pizza-server"
SERVER_PORT=3000
NINJA_JOBS=2   # parallel compile jobs — keep at 2 to avoid OOM on Codespaces

# ────────────────────────────────────────────────────────────
# SANITY CHECKS
# ────────────────────────────────────────────────────────────
header "Checking environment"

# Must be running inside the repo
if [ ! -f "$REPO_DIR/CMakeLists.txt" ]; then
    error "Cannot find $REPO_DIR/CMakeLists.txt — are you running this inside the correct Codespace? Expected repo at $REPO_DIR"
fi
success "Repo found at $REPO_DIR"

# Must be running in Codespaces or at least Linux
if [[ "$OSTYPE" != "linux-gnu"* ]]; then
    error "This script must be run on Linux (GitHub Codespaces). Detected OS: $OSTYPE"
fi
success "Linux detected"

# Check FMOD files were committed to the fork
if [ ! -f "$FMOD_HTML5_ROOT/lib/w32/fmodP_wasm.a" ]; then
    error "FMOD HTML5 wasm library not found at $FMOD_HTML5_ROOT/lib/w32/fmodP_wasm.a\n\n  You must commit the FMOD HTML5 SDK files to your fork first.\n  See the guide: add fmod-html5/lib/w32/fmodP_wasm.a and fmod-html5/inc/ to your repo.\n\n  Download FMOD HTML5 SDK from https://www.fmod.com/download"
fi
if [ ! -d "$FMOD_HTML5_ROOT/inc" ]; then
    error "FMOD HTML5 headers not found at $FMOD_HTML5_ROOT/inc/\n\n  Commit the FMOD HTML5 inc/ folder to fmod-html5/inc/ in your fork."
fi
success "FMOD HTML5 SDK found"

# ────────────────────────────────────────────────────────────
# STEP 1 — SYSTEM DEPENDENCIES
# ────────────────────────────────────────────────────────────
header "Step 1/9 — Installing system dependencies"

PACKAGES=(
    cmake
    ninja-build
    clang
    libgl-dev
    libegl-dev
    libglew-dev
    xvfb
    python3
    python3-pip
    curl
    unzip
    zip
    git
    pkg-config
    libssl-dev
)

mkdir -p "$TOOLS_DIR"

MISSING_COMMANDS=()
for cmd in cmake git curl python3; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
        MISSING_COMMANDS+=("$cmd")
    fi
done

if [ ${#MISSING_COMMANDS[@]} -gt 0 ]; then
    if command -v sudo > /dev/null 2>&1; then
        sudo apt-get update -qq
        log "Installing: ${PACKAGES[*]}"
        sudo apt-get install -y "${PACKAGES[@]}" > /dev/null 2>&1
        success "System packages installed"
    else
        error "Missing required commands: ${MISSING_COMMANDS[*]}. Install system dependencies, then rerun this script."
    fi
else
    success "Required base commands found"
fi

# Ninja is required by CMakePresets.json. If apt/sudo is unavailable, install a
# workspace-local copy from PyPI instead of writing into the user environment.
if ! command -v ninja > /dev/null 2>&1; then
    log "ninja not found; installing workspace-local ninja package..."
    python3 -m pip install --prefix "$TOOLS_DIR/python" ninja > /dev/null 2>&1
    export PATH="$TOOLS_DIR/python/bin:$PATH"
fi

if ! command -v ninja > /dev/null 2>&1; then
    error "ninja is required but could not be installed"
fi
success "Ninja found: $(command -v ninja)"

# Node.js (need v18+)
if ! command -v node &> /dev/null || [[ $(node -v | cut -d. -f1 | tr -d v) -lt 18 ]]; then
    log "Installing Node.js 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - > /dev/null 2>&1
    sudo apt-get install -y nodejs > /dev/null 2>&1
fi
NODE_VER=$(node -v)
success "Node.js $NODE_VER installed"

# ────────────────────────────────────────────────────────────
# STEP 2 — EMSDK
# ────────────────────────────────────────────────────────────
header "Step 2/9 — Setting up Emscripten (EMSDK)"

if [ -d "$EMSDK_DIR" ]; then
    log "EMSDK already cloned, updating..."
    cd "$EMSDK_DIR" && git pull --quiet
else
    log "Cloning EMSDK..."
    git clone https://github.com/emscripten-core/emsdk.git "$EMSDK_DIR" --quiet
fi

cd "$EMSDK_DIR"
log "Installing latest Emscripten..."
./emsdk install latest 2>&1 | tail -5
./emsdk activate latest > /dev/null 2>&1
source "$EMSDK_DIR/emsdk_env.sh" > /dev/null 2>&1

# Add to .bashrc if not already there
log "EMSDK environment active for this build"

EMCC_VER=$(emcc --version 2>&1 | head -1)
success "Emscripten ready: $EMCC_VER"

# ────────────────────────────────────────────────────────────
# STEP 3 — VCPKG
# ────────────────────────────────────────────────────────────
header "Step 3/9 — Setting up vcpkg"

if [ -d "$VCPKG_DIR" ]; then
    log "vcpkg already cloned, updating..."
    cd "$VCPKG_DIR" && git pull --quiet
else
    log "Cloning vcpkg..."
    git clone https://github.com/microsoft/vcpkg.git "$VCPKG_DIR" --quiet
fi

cd "$VCPKG_DIR"
if [ ! -f "$VCPKG_DIR/vcpkg" ]; then
    log "Bootstrapping vcpkg..."
    ./bootstrap-vcpkg.sh -disableMetrics > /dev/null 2>&1
fi

export VCPKG_ROOT="$VCPKG_DIR"
log "VCPKG_ROOT active for this build"

success "vcpkg ready at $VCPKG_DIR"

# ────────────────────────────────────────────────────────────
# STEP 4 — FMOD ENV VAR
# ────────────────────────────────────────────────────────────
header "Step 4/9 — Configuring FMOD"

export FMOD_HTML5_ROOT="$FMOD_HTML5_ROOT"
log "FMOD_HTML5_ROOT active for this build"

success "FMOD_HTML5_ROOT = $FMOD_HTML5_ROOT"
log "  wasm lib : $FMOD_HTML5_ROOT/lib/w32/fmodP_wasm.a"
log "  headers  : $FMOD_HTML5_ROOT/inc/"

# ────────────────────────────────────────────────────────────
# STEP 5 — .ASSETS FOLDERS
# ────────────────────────────────────────────────────────────
header "Step 5/9 — Preparing .assets folders"

ASSETS_DIR="$REPO_DIR/.assets"

mkdir -p "$ASSETS_DIR/content"
mkdir -p "$ASSETS_DIR/shaders"
mkdir -p "$ASSETS_DIR/PlatformContent"

CONTENT_FILES=$(find "$ASSETS_DIR/content" -type f 2>/dev/null | wc -l)
SHADER_FILES=$(find "$ASSETS_DIR/shaders" -type f 2>/dev/null | wc -l)

if [ "$CONTENT_FILES" -eq 0 ]; then
    warn "content/ folder is empty — client will compile but crash on boot with missing assets."
    warn "Upload old Roblox content files (circa 2015-2016) to .assets/content/ in your fork."
else
    success "content/ has $CONTENT_FILES files"
fi

if [ "$SHADER_FILES" -eq 0 ]; then
    warn "shaders/ folder is empty"
else
    success "shaders/ has $SHADER_FILES files"
fi

# ────────────────────────────────────────────────────────────
# STEP 6 — CMAKE CONFIGURE
# ────────────────────────────────────────────────────────────
header "Step 6/9 — CMake configure (emscripten-release)"

log "This step runs vcpkg to download and build all dependencies."
log "First run takes 40–60 minutes. Subsequent runs are fast (cached)."
log ""

# Check if already configured and cached
if [ -f "$BUILD_DIR/CMakeCache.txt" ]; then
    log "CMakeCache found — skipping full reconfigure (using cached build)."
    log "To force full reconfigure: rm -rf $BUILD_DIR"
else
    log "No cache found — running full configure..."
fi

cd "$REPO_DIR"

START_TIME=$SECONDS

cmake --preset emscripten-release \
    -DVCPKG_ROOT="$VCPKG_DIR" \
    -DFMOD_HTML5_ROOT="$FMOD_HTML5_ROOT"

ELAPSED=$((SECONDS - START_TIME))
success "Configure complete in ${ELAPSED}s"

# ────────────────────────────────────────────────────────────
# STEP 7 — CMAKE BUILD
# ────────────────────────────────────────────────────────────
header "Step 7/9 — Building UniversalClient"

log "Building with $NINJA_JOBS parallel jobs (keep low to avoid OOM)..."
log "This takes 10–20 minutes..."

START_TIME=$SECONDS

cmake --build "$BUILD_DIR" -- -j$NINJA_JOBS

ELAPSED=$((SECONDS - START_TIME))
success "Build complete in ${ELAPSED}s"

# Verify output files exist
REQUIRED_FILES=("UniversalClient.html" "UniversalClient.js" "UniversalClient.wasm")
for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$BUILD_DIR/$f" ]; then
        error "Expected output file missing: $BUILD_DIR/$f — build may have failed"
    fi
done

WASM_SIZE=$(du -sh "$BUILD_DIR/UniversalClient.wasm" | cut -f1)
JS_SIZE=$(du -sh "$BUILD_DIR/UniversalClient.js" | cut -f1)
success "Output files:"
log "  UniversalClient.wasm : $WASM_SIZE"
log "  UniversalClient.js   : $JS_SIZE"
if [ -f "$BUILD_DIR/UniversalClient.data" ]; then
    DATA_SIZE=$(du -sh "$BUILD_DIR/UniversalClient.data" | cut -f1)
    log "  UniversalClient.data : $DATA_SIZE"
fi

# ────────────────────────────────────────────────────────────
# STEP 8 — PATCH HTML SHELL
# ────────────────────────────────────────────────────────────
header "Step 8/9 — Patching UniversalClient.html"

HTML_FILE="$BUILD_DIR/UniversalClient.html"

# Detect Codespace URL
if [ -n "$CODESPACE_NAME" ]; then
    BASE_URL="https://${CODESPACE_NAME}-${SERVER_PORT}.app.github.dev"
    log "Detected Codespace: $CODESPACE_NAME"
    log "Base URL will be: $BASE_URL"
else
    BASE_URL="http://localhost:${SERVER_PORT}"
    warn "CODESPACE_NAME not set — using localhost. If running in Codespaces, this should be set automatically."
fi

MODULE_SCRIPT="<script>
var Module = {
    fastFlags: '{}',
    arguments: [
        \"--baseUrl\",              \"${BASE_URL}/\",
        \"--authenticationUrl\",    \"${BASE_URL}/login/negotiate.ashx\",
        \"--authenticationTicket\", \"0_LOCALTICKET\",
        \"--joinScriptUrl\",        \"${BASE_URL}/game/join.ashx?placeId=1818\"
    ]
};
</script>"

# Only patch if not already patched
if grep -q "var Module" "$HTML_FILE"; then
    warn "HTML already patched (Module block already present) — skipping patch."
    warn "To repatch, remove the existing <script>var Module...</script> block from $HTML_FILE"
else
    # Insert before the UniversalClient.js script tag
    SEARCH='<script src="UniversalClient.js"></script>'
    REPLACE="${MODULE_SCRIPT}
<script src=\"UniversalClient.js\"></script>"

    # Use python for reliable in-place string replacement (no BSD sed issues)
    python3 - "$HTML_FILE" "$SEARCH" "$REPLACE" << 'PYEOF'
import sys
path, search, replace = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, 'r') as f:
    content = f.read()
if search not in content:
    print(f"ERROR: Could not find marker '{search}' in {path}", file=sys.stderr)
    sys.exit(1)
with open(path, 'w') as f:
    f.write(content.replace(search, replace, 1))
print("Patched successfully")
PYEOF

    success "HTML shell patched with Module.arguments"
    log "  baseUrl: ${BASE_URL}/"
fi

# ────────────────────────────────────────────────────────────
# STEP 9 — NODE.JS API SERVER
# ────────────────────────────────────────────────────────────
header "Step 9/9 — Setting up API server"

mkdir -p "$SERVER_DIR"
cd "$SERVER_DIR"

# Init package.json if needed
if [ ! -f "$SERVER_DIR/package.json" ]; then
    npm init -y > /dev/null 2>&1
fi

# Install deps
log "Installing express and axios..."
npm install express axios --save > /dev/null 2>&1
success "npm packages installed"

# Write server.js
cat > "$SERVER_DIR/server.js" << SERVEREOF
const express = require('express');
const axios   = require('axios');
const path    = require('path');
const app     = express();

const BASE_URL  = process.env.BASE_URL  || '${BASE_URL}';
const RCC_URL   = process.env.RCC_URL   || 'http://localhost:64989';
const PORT      = process.env.PORT      || ${SERVER_PORT};
const BUILD_DIR = '${BUILD_DIR}';

// ── Required headers for WebAssembly SharedArrayBuffer (pthreads) ──
app.use((req, res, next) => {
    res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
    res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
    next();
});

app.use(express.json());
app.use(express.text({ type: ['text/xml', 'application/xml', 'text/plain'] }));

// ── Serve built wasm files ──
app.use(express.static(BUILD_DIR));

// ── Auth endpoint ──
app.post('/login/negotiate.ashx', (req, res) => {
    console.log('[Auth] Ticket request received');
    res.send('0_LOCALTICKET');
});

// ── Join script endpoint ──
app.get('/game/join.ashx', async (req, res) => {
    const placeId = req.query.placeId || 1818;
    console.log('[Join] Request for placeId=' + placeId);

    // Send OpenJob to RCCService
    try {
        await openRCCJob(placeId, 53640);
        console.log('[Join] RCCService job opened');
    } catch(e) {
        console.error('[Join] Failed to open RCC job:', e.message);
        console.error('[Join] Is RCCService running? Is RCC_URL correct?');
        console.error('[Join] RCC_URL =', RCC_URL);
    }

    // Return join script — client connects via websockify on 53641
    res.type('text/plain').send(\`
local placeId = \${placeId}
local port    = 53641
local serverAddress = "\${getRCCHost()}"
local userId  = 1
local characterAppearance = "\${BASE_URL}/asset/characterfetch.ashx?userId=1"
local gameId  = "00000000-0000-0000-0000-000000000000"
local sessionId = "00000000-0000-0000-0000-000000000001"
local clientTicket = "0_LOCALTICKET"
game:GetService("NetworkClient"):PlayerConnect(
    userId, serverAddress, port, 0,
    clientTicket, "\${BASE_URL}/",
    characterAppearance, userId,
    "TestUser", false, "",
    gameId, sessionId, placeId
)
\`);
});

// ── Stub asset endpoint ──
app.get('/asset/*', (req, res) => {
    console.log('[Asset] Request:', req.path);
    res.status(404).send('Asset not found');
});

// ── Extract hostname from RCC_URL ──
function getRCCHost() {
    try { return new URL(RCC_URL).hostname; }
    catch { return 'localhost'; }
}

// ── Send OpenJob SOAP to RCCService ──
async function openRCCJob(placeId, port) {
    const script = \`
game.PlaceId = \${placeId}
game:GetService("DataModel"):Load("rbxasset://places/empty.rbxl")
local ns = game:GetService("NetworkServer")
ns:Start(\${port}, 100)
print("Game server started on port \${port}")
\`;

    // Escape XML special chars in script
    const safeScript = script
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');

    const soap = \`<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
               xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <soap:Body>
    <OpenJob xmlns="http://roblox.com/">
      <job>
        <id>job-\${Date.now()}</id>
        <expirationInSeconds>3600</expirationInSeconds>
        <category>0</category>
        <cores>1</cores>
      </job>
      <script>
        <name>GameScript</name>
        <script>\${safeScript}</script>
        <arguments/>
      </script>
    </OpenJob>
  </soap:Body>
</soap:Envelope>\`;

    console.log('[RCC] Sending OpenJob to', RCC_URL);
    const response = await axios.post(RCC_URL, soap, {
        headers: {
            'Content-Type': 'text/xml; charset=utf-8',
            'SOAPAction':   '"OpenJob"'
        },
        timeout: 10000
    });
    return response.data;
}

app.listen(PORT, () => {
    console.log('');
    console.log('╔══════════════════════════════════════════╗');
    console.log('║        Pizza API Server Running          ║');
    console.log('╠══════════════════════════════════════════╣');
    console.log(\`║  Port     : \${PORT}\`);
    console.log(\`║  Base URL : \${BASE_URL}\`);
    console.log(\`║  RCC URL  : \${RCC_URL}\`);
    console.log('╠══════════════════════════════════════════╣');
    console.log(\`║  Open: \${BASE_URL}/UniversalClient.html\`);
    console.log('╚══════════════════════════════════════════╝');
    console.log('');
});
SERVEREOF

success "server.js written to $SERVER_DIR/server.js"

# ────────────────────────────────────────────────────────────
# KILL OLD SERVER IF RUNNING
# ────────────────────────────────────────────────────────────
OLD_PID=$(lsof -ti:$SERVER_PORT 2>/dev/null || true)
if [ -n "$OLD_PID" ]; then
    warn "Killing old process on port $SERVER_PORT (PID $OLD_PID)"
    kill "$OLD_PID" 2>/dev/null || true
    sleep 1
fi

# ────────────────────────────────────────────────────────────
# START SERVER
# ────────────────────────────────────────────────────────────
log "Starting API server on port $SERVER_PORT..."
cd "$SERVER_DIR"
nohup node server.js > "$SERVER_DIR/server.log" 2>&1 &
SERVER_PID=$!
echo $SERVER_PID > "$SERVER_DIR/server.pid"

# Wait a moment and check it started
sleep 2
if kill -0 $SERVER_PID 2>/dev/null; then
    success "API server started (PID $SERVER_PID)"
else
    error "API server failed to start. Check log: $SERVER_DIR/server.log"
fi

# ────────────────────────────────────────────────────────────
# FINAL SUMMARY
# ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║              BUILD COMPLETE                              ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${GREEN}║${NC}  Output: $BUILD_DIR"
echo -e "${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}  ${BOLD}NEXT STEPS:${NC}"
echo -e "${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}  1. In the Codespaces PORTS tab, set port $SERVER_PORT to PUBLIC"
echo -e "${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}  2. Open in your browser:"
echo -e "${BOLD}${GREEN}║${NC}     ${CYAN}${BASE_URL}/UniversalClient.html${NC}"
echo -e "${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}  3. For multiplayer, also run build-rcc.sh in Codespace B"
echo -e "${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}  Server log: $SERVER_DIR/server.log"
echo -e "${BOLD}${GREEN}║${NC}  Stop server: kill \$(cat $SERVER_DIR/server.pid)"
echo -e "${BOLD}${GREEN}║${NC}"
if [ -z "$CONTENT_FILES" ] || [ "$CONTENT_FILES" -eq 0 ]; then
echo -e "${BOLD}${GREEN}║${NC}  ${YELLOW}WARNING: .assets/content/ is empty.${NC}"
echo -e "${BOLD}${GREEN}║${NC}  ${YELLOW}Client will load but render nothing.${NC}"
echo -e "${BOLD}${GREEN}║${NC}  ${YELLOW}Add old Roblox content files to .assets/content/${NC}"
fi
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
