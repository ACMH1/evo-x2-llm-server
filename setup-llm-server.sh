#!/usr/bin/env bash
# =============================================================================
# GMKtec EVO-X2 LLM Server Setup
# Hardware: Ryzen AI MAX+ 395 (Strix Halo), 128 GB RAM (95.2 GB iGPU VRAM+GTT), 2 TB NVMe
# OS:       Fedora 43 Server (default partitioning with LVM)
#
# What this script does:
#   1. Expands the root LV and creates a dedicated /models volume
#   2. Adds GPU device access groups
#   3. Installs rocm-smi for diagnostics
#   4. Verifies Podman is available (pre-installed on Fedora)
#   5. Runs Ollama as a Podman container (ollama/ollama:rocm) with GPU passthrough
#      and generates a systemd service for auto-start
#   6. Opens the firewall port
#   7. Sets a static IP (using the current DHCP-assigned address)
#   8. Pulls qwen2.5-coder:32b
#   9. Creates a 'coder' model alias
#  10. Installs an ollama-status utility
#
# Usage:
#   sudo bash setup-llm-server.sh
#
# The script is idempotent — safe to re-run on a partially set-up machine.
# Full log is written to /var/log/llm-server-setup.log
# =============================================================================

set -euo pipefail

# ── CONFIGURATION (edit these before running if needed) ──────────────────────

# Storage
ROOT_LV_SIZE="100G"          # How large to make the root logical volume
MODELS_DIR="/models"         # Mount point for the dedicated model storage LV

# Container
CONTAINER_IMAGE="docker.io/ollama/ollama:rocm"
CONTAINER_NAME="ollama"

# ROCm
# The GFX override makes ROCm treat Strix Halo (gfx1151) as gfx1100.
# Remove once AMD adds official gfx1151 support.
HSA_GFX_OVERRIDE="11.0.0"

# Ollama
OLLAMA_PORT="11434"
# Context window per model alias. Ollama auto-detects ~262K from 95 GB VRAM;
# 32768 is a practical cap — large enough for big codebases, avoids very long prefills.
OLLAMA_CTX="32768"

# Network
# Leave STATIC_IP / GATEWAY empty to auto-detect from the current DHCP lease.
STATIC_IP=""
GATEWAY=""
DNS_SERVERS="8.8.8.8 8.8.4.4"

# Models to pull
MODELS_TO_PULL=(
    "qwen2.5-coder:32b"
)

# Named aliases exposed to clients.
# Format: "alias_name|base_model_tag|system_prompt"
MODEL_ALIASES=(
    "coder|qwen2.5-coder:32b|You are an expert coding assistant. Provide clean, correct, well-structured code."
)

# ── END CONFIGURATION ─────────────────────────────────────────────────────────

LOG_FILE="/var/log/llm-server-setup.log"
SCRIPT_START=$(date '+%Y-%m-%d %H:%M:%S')

exec > >(tee -a "$LOG_FILE") 2>&1

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'

log()  { echo -e "${B}[$(date '+%H:%M:%S')]${N} $*"; }
ok()   { echo -e "${G}[$(date '+%H:%M:%S')] ✓${N} $*"; }
warn() { echo -e "${Y}[$(date '+%H:%M:%S')] ⚠${N}  $*"; }
die()  { echo -e "${R}[$(date '+%H:%M:%S')] ✗${N} $*" >&2; exit 1; }
step() { echo -e "\n${B}━━━ $* ━━━${N}"; }

ollama_exec() { podman exec "$CONTAINER_NAME" ollama "$@"; }


# =============================================================================
# PREFLIGHT
# =============================================================================

preflight() {
    step "Preflight checks"

    [[ $EUID -eq 0 ]] || die "Must be run as root: sudo bash $0"

    if ! grep -qi "fedora" /etc/os-release 2>/dev/null; then
        warn "This script targets Fedora. Detected OS may differ — proceeding anyway."
    else
        local ver
        ver=$(grep VERSION_ID /etc/os-release | cut -d= -f2)
        ok "OS: Fedora $ver"
    fi

    if [[ -c /dev/kfd ]]; then
        ok "/dev/kfd present (AMDGPU driver loaded)"
    else
        warn "/dev/kfd missing. ROCm will not detect the GPU. Try rebooting first."
    fi

    if lspci 2>/dev/null | grep -qi "Strix Halo"; then
        ok "Strix Halo GPU found in lspci"
    else
        warn "Strix Halo not found in lspci — wrong machine, or driver issue"
    fi

    local ram_gb
    ram_gb=$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)
    ok "System RAM: ${ram_gb} GB"
    (( ram_gb >= 48 )) || warn "Less RAM than expected. Check BIOS iGPU memory allocation."

    local missing=()
    for cmd in lspci lvm lvextend lvcreate mkfs.xfs nmcli firewall-cmd python3 curl podman; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        log "Installing missing tools: ${missing[*]}"
        dnf install -y "${missing[@]}" 2>/dev/null || \
            warn "Could not install some tools. Continuing."
    fi
    ok "All required tools present"
}


# =============================================================================
# STEP 1 — STORAGE
# =============================================================================

setup_storage() {
    step "Step 1: Storage"

    local vg
    vg=$(vgs --noheadings -o vg_name 2>/dev/null | tr -d ' ' | head -1)
    [[ -n "$vg" ]] || die "No LVM volume group found. Is this a default Fedora Server install?"
    log "Volume group: $vg"

    local root_lv="/dev/${vg}/root"
    [[ -b "$root_lv" ]] || die "Expected root LV at $root_lv — not found."

    local current_gb
    current_gb=$(lvs --noheadings --units g -o lv_size "$root_lv" \
                 | tr -d ' <' | sed 's/g.*//')
    current_gb=${current_gb%%.*}

    if (( current_gb >= 90 )); then
        ok "Root LV already ${current_gb} GB — skipping extension"
    else
        log "Extending root LV: ${current_gb} GB → ${ROOT_LV_SIZE}"
        lvextend -L "${ROOT_LV_SIZE}" "$root_lv" || {
            warn "Could not set exact size. Using all free space."
            lvextend -l +100%FREE "$root_lv" || true
        }
        if xfs_growfs / 2>/dev/null; then
            ok "XFS filesystem grown"
        elif resize2fs "$root_lv" 2>/dev/null; then
            ok "ext4 filesystem grown"
        else
            warn "Could not automatically grow filesystem — do it manually."
        fi
    fi

    local models_lv="/dev/${vg}/models"

    if lvs "$models_lv" &>/dev/null; then
        ok "/models LV already exists"
    else
        local free_gb
        free_gb=$(vgs --noheadings --units g -o vg_free "$vg" \
                  | tr -d ' <' | sed 's/g.*//')
        free_gb=${free_gb%%.*}

        if (( free_gb < 50 )); then
            warn "Only ${free_gb} GB free in VG — skipping /models LV."
        else
            log "Creating /models LV (${free_gb} GB available)..."
            lvcreate -l 100%FREE -n models "$vg"
            mkfs.xfs "$models_lv"
            ok "/models LV created (${free_gb} GB)"
        fi
    fi

    mkdir -p "${MODELS_DIR}"

    local fstab_dev="/dev/${vg}/models"
    if ! grep -qE "${fstab_dev}|/dev/mapper/${vg}-models" /etc/fstab 2>/dev/null; then
        echo "${fstab_dev} ${MODELS_DIR} xfs defaults 0 0" >> /etc/fstab
        log "Added ${MODELS_DIR} to /etc/fstab"
    fi

    if mountpoint -q "${MODELS_DIR}"; then
        ok "${MODELS_DIR} already mounted"
    else
        mount "${MODELS_DIR}" && ok "${MODELS_DIR} mounted"
    fi

    df -h "${MODELS_DIR}" /
}


# =============================================================================
# STEP 2 — GPU ACCESS GROUPS
# =============================================================================

setup_gpu_groups() {
    step "Step 2: GPU access groups"

    for grp in video render; do
        if getent group "$grp" &>/dev/null; then
            usermod -aG "$grp" root
            ok "root → $grp"
        else
            warn "Group '$grp' does not exist — skipping"
        fi
    done
}


# =============================================================================
# STEP 3 — ROCm DIAGNOSTICS
# =============================================================================

setup_rocm() {
    step "Step 3: ROCm diagnostics (rocm-smi)"

    # ROCm compute libraries are bundled inside the Ollama container image.
    # We only install rocm-smi on the host for monitoring/diagnostics.
    if command -v rocm-smi &>/dev/null; then
        ok "rocm-smi already installed"
        return
    fi

    log "Installing rocm-smi for diagnostics..."
    if dnf install -y rocm-smi 2>/dev/null; then
        ok "rocm-smi installed"
    else
        warn "rocm-smi not available via dnf — install manually if needed for diagnostics"
    fi
}


# =============================================================================
# STEP 4 — PODMAN
# =============================================================================

verify_podman() {
    step "Step 4: Podman"

    if ! command -v podman &>/dev/null; then
        log "Installing Podman..."
        dnf install -y podman
    fi
    ok "Podman $(podman --version | awk '{print $3}')"

    log "Pulling container image: ${CONTAINER_IMAGE}"
    podman pull "${CONTAINER_IMAGE}"
    ok "Image pulled: ${CONTAINER_IMAGE}"
}


# =============================================================================
# STEP 5 — OLLAMA CONTAINER SERVICE
# =============================================================================

configure_ollama_container() {
    step "Step 5: Ollama container service"

    # Stop and remove any existing container
    if podman ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log "Removing existing container: ${CONTAINER_NAME}"
        podman rm -f "${CONTAINER_NAME}"
    fi

    # Container runs as root; ensure /models is owned accordingly
    chown -R root:root "${MODELS_DIR}"
    ok "Ownership of ${MODELS_DIR} set to root:root"

    log "Starting Ollama container..."
    podman run -d \
        --name "${CONTAINER_NAME}" \
        --device /dev/kfd \
        --device /dev/dri \
        -v "${MODELS_DIR}:/root/.ollama/models" \
        -p "${OLLAMA_PORT}:${OLLAMA_PORT}" \
        -e HSA_OVERRIDE_GFX_VERSION="${HSA_GFX_OVERRIDE}" \
        -e OLLAMA_HOST="0.0.0.0:${OLLAMA_PORT}" \
        "${CONTAINER_IMAGE}"

    # Generate and enable a systemd service for auto-start on boot
    podman generate systemd \
        --name "${CONTAINER_NAME}" \
        --restart-policy=always \
        --new \
        > /etc/systemd/system/ollama-container.service

    systemctl daemon-reload
    systemctl enable ollama-container
    ok "Systemd service: ollama-container (enabled)"

    # Wait for Ollama to be ready
    log "Waiting for Ollama API..."
    local attempts=0
    while ! curl -sf "http://localhost:${OLLAMA_PORT}/" &>/dev/null; do
        sleep 2
        (( ++attempts > 20 )) && die "Ollama did not become ready after 40s. Check: podman logs ${CONTAINER_NAME}"
    done
    ok "Ollama API is responding"

    # Confirm GPU detection
    local gpu_line
    gpu_line=$(podman logs "${CONTAINER_NAME}" 2>&1 | grep "inference compute" | tail -1)
    if [[ -n "$gpu_line" ]]; then
        ok "GPU confirmed: $gpu_line"
    else
        warn "GPU not yet in logs — will appear after first model load"
    fi
}


# =============================================================================
# STEP 6 — FIREWALL
# =============================================================================

configure_firewall() {
    step "Step 6: Firewall"

    if ! systemctl is-active --quiet firewalld 2>/dev/null; then
        warn "firewalld is not running — skipping firewall configuration"
        return
    fi

    if firewall-cmd --list-ports 2>/dev/null | grep -q "${OLLAMA_PORT}/tcp"; then
        ok "Port ${OLLAMA_PORT}/tcp already open"
    else
        firewall-cmd --add-port="${OLLAMA_PORT}/tcp" --permanent
        firewall-cmd --reload
        ok "Port ${OLLAMA_PORT}/tcp opened"
    fi
}


# =============================================================================
# STEP 7 — STATIC IP
# =============================================================================

configure_static_ip() {
    step "Step 7: Static IP"

    local iface
    iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    if [[ -z "$iface" ]]; then
        warn "No default route interface found — skipping static IP"
        return
    fi
    log "Primary interface: $iface"

    local method
    method=$(nmcli -g ipv4.method con show "$iface" 2>/dev/null || echo "")
    if [[ "$method" == "manual" ]]; then
        local current_addr
        current_addr=$(nmcli -g ipv4.addresses con show "$iface" 2>/dev/null || echo "(unknown)")
        ok "Interface $iface already static: $current_addr"
        return
    fi

    if [[ -z "$STATIC_IP" ]]; then
        STATIC_IP=$(ip addr show "$iface" | awk '/inet / {print $2}' | head -1)
    fi
    if [[ -z "$GATEWAY" ]]; then
        GATEWAY=$(ip route show default | awk '{print $3}' | head -1)
    fi

    if [[ -z "$STATIC_IP" || -z "$GATEWAY" ]]; then
        warn "Could not determine IP ($STATIC_IP) or gateway ($GATEWAY) — skipping static IP"
        return
    fi

    log "Setting $iface → $STATIC_IP via $GATEWAY"
    nmcli con mod "$iface" \
        ipv4.method    manual \
        ipv4.addresses "$STATIC_IP" \
        ipv4.gateway   "$GATEWAY" \
        ipv4.dns       "$GATEWAY $DNS_SERVERS"
    nmcli con up "$iface" &>/dev/null || true
    ok "Static IP configured: $STATIC_IP"
}


# =============================================================================
# STEP 8 — PULL MODELS
# =============================================================================

pull_models() {
    step "Step 8: Pulling models"

    for model in "${MODELS_TO_PULL[@]}"; do
        if python3 - "$model" <<'PYEOF'
import sys, urllib.request, json
model = sys.argv[1]
try:
    with urllib.request.urlopen("http://localhost:11434/api/tags", timeout=5) as r:
        data = json.load(r)
    names = [m["name"] for m in data.get("models", [])]
    base, _, tag = model.partition(":")
    tag = tag or "latest"
    if model in names or f"{base}:{tag}" in names:
        print(f"  already present: {model}")
        sys.exit(0)
    sys.exit(1)
except Exception as e:
    print(f"  check failed: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
        then
            ok "$model already pulled"
            continue
        fi

        log "Pulling $model — this may take several minutes..."
        ollama_exec pull "$model"
        ok "$model pulled"
    done
}


# =============================================================================
# STEP 9 — MODEL ALIASES
# =============================================================================

create_model_aliases() {
    step "Step 9: Creating model aliases"

    mkdir -p "${MODELS_DIR}/modelfiles"

    for entry in "${MODEL_ALIASES[@]}"; do
        IFS='|' read -r alias base_model system_prompt <<< "$entry"

        local modelfile="${MODELS_DIR}/modelfiles/${alias}.Modelfile"

        cat > "$modelfile" <<MFEOF
FROM ${base_model}
PARAMETER num_ctx ${OLLAMA_CTX}
PARAMETER num_predict 4096
SYSTEM "${system_prompt}"
MFEOF

        log "Creating alias: $alias → $base_model (ctx=${OLLAMA_CTX})"
        ollama_exec create "$alias" -f "/root/.ollama/models/modelfiles/${alias}.Modelfile"
        ok "Alias '$alias' created"
    done
}


# =============================================================================
# STEP 10 — UTILITY SCRIPT
# =============================================================================

install_status_script() {
    step "Step 10: Installing ollama-status utility"

    cat > /usr/local/bin/ollama-status <<'STATUSEOF'
#!/usr/bin/env bash
# Quick status overview for the Ollama LLM server on GMKtec EVO-X2

echo "=== Container ==="
if podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^ollama$"; then
    echo "  ollama: running"
    echo "  image:  $(podman inspect ollama --format '{{.ImageName}}' 2>/dev/null)"
else
    echo "  ollama: STOPPED"
    echo "  start with: systemctl start ollama-container"
fi

echo ""
echo "=== GPU (Strix Halo — gfx1100 override) ==="
if command -v rocm-smi &>/dev/null; then
    HSA_OVERRIDE_GFX_VERSION=11.0.0 rocm-smi 2>/dev/null
else
    echo "  rocm-smi not found — install for GPU diagnostics"
fi

echo ""
echo "=== Loaded models (in VRAM) ==="
python3 - <<'PYEOF'
import urllib.request, json
try:
    with urllib.request.urlopen("http://localhost:11434/api/ps", timeout=3) as r:
        data = json.load(r)
    models = data.get("models", [])
    if not models:
        print("  (none)")
    for m in models:
        gb = m.get("size_vram", 0) / 1024**3
        ctx = m.get("context_length", 0)
        print(f"  {m['name']:<35} {gb:.1f} GB VRAM  ctx={ctx}")
except Exception as e:
    print(f"  (error: {e})")
PYEOF

echo ""
echo "=== Available models ==="
python3 - <<'PYEOF'
import urllib.request, json
try:
    with urllib.request.urlopen("http://localhost:11434/api/tags", timeout=3) as r:
        data = json.load(r)
    models = data.get("models", [])
    if not models:
        print("  (none)")
    for m in models:
        gb = m.get("size", 0) / 1024**3
        print(f"  {m['name']:<35} {gb:.1f} GB")
except Exception as e:
    print(f"  (error: {e})")
PYEOF

echo ""
echo "=== Storage ==="
df -h /models / 2>/dev/null | awk 'NR==1 || /\/models|\/dev/'
STATUSEOF

    chmod +x /usr/local/bin/ollama-status
    ok "ollama-status installed at /usr/local/bin/ollama-status"
}


# =============================================================================
# MAIN
# =============================================================================

main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║  GMKtec EVO-X2 LLM Server Setup                          ║"
    echo "║  Strix Halo · Fedora 43 · Ollama (Podman) + ROCm         ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo "  Started: $SCRIPT_START"
    echo "  Log:     $LOG_FILE"
    echo ""

    preflight
    setup_storage
    setup_gpu_groups
    setup_rocm
    verify_podman
    configure_ollama_container
    configure_firewall
    configure_static_ip
    pull_models
    create_model_aliases
    install_status_script

    local server_ip
    server_ip=$(ip addr show \
                | awk '/inet / && !/127\.0\.0\.1/{print $2}' \
                | head -1 | cut -d/ -f1)

    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║  Setup complete                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Ollama API:  http://${server_ip}:${OLLAMA_PORT}"
    echo "  Models dir:  ${MODELS_DIR}"
    echo ""
    echo "  Aliases:"
    for entry in "${MODEL_ALIASES[@]}"; do
        IFS='|' read -r alias base_model _ <<< "$entry"
        printf "    %-12s →  %s\n" "$alias" "$base_model"
    done
    echo ""
    echo "  Quick status:  ollama-status"
    echo "  Container logs:  podman logs -f ollama"
    echo "  Full log:      $LOG_FILE"
    echo ""
    echo "  Example (from any LAN machine):"
    echo "    curl http://${server_ip}:${OLLAMA_PORT}/api/generate \\"
    echo "      -d '{\"model\":\"coder\",\"prompt\":\"hello\",\"stream\":false}'"
    echo ""

    ollama-status
}

main "$@"
