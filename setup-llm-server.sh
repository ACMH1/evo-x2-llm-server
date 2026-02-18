#!/usr/bin/env bash
# =============================================================================
# GMKtec EVO-X2 LLM Server Setup
# Hardware: Ryzen AI MAX+ 395 (Strix Halo), 128 GB RAM (64 GB iGPU VRAM), 2 TB NVMe
# OS:       Fedora 43 Server (default partitioning with LVM)
#
# What this script does:
#   1. Expands the root LV and creates a dedicated /models volume
#   2. Adds GPU device access groups
#   3. Installs ROCm (via AMD's RHEL9-compatible repo)
#   4. Installs Ollama (with bundled ROCm)
#   5. Configures the Ollama systemd service for LAN access + Strix Halo workaround
#   6. Opens the firewall port
#   7. Sets a static IP (using the current DHCP-assigned address)
#   8. Pulls qwen2.5-coder:32b and deepseek-r1:32b
#   9. Creates 'coder' and 'planner' model aliases with sane context limits
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

# ROCm
# The GFX override makes ROCm treat Strix Halo (gfx1151) as gfx1100.
# Remove once AMD adds official gfx1151 support.
HSA_GFX_OVERRIDE="11.0.0"
ROCM_VERSION="6.3"                     # AMD ROCm repo version to use
ROCM_RHEL_VER="9.4"                    # RHEL-compatible base for repo URL

# Ollama
OLLAMA_PORT="11434"
# Context window per model. The Strix Halo has ~95 GB of combined VRAM+GTT,
# so Ollama auto-selects 262K ctx — which burns ~28 GB on KV cache alone.
# 16384 keeps each 32B model under 24 GB, allowing both to coexist.
OLLAMA_CTX="16384"

# Network
# Leave STATIC_IP / GATEWAY empty to auto-detect from the current DHCP lease.
STATIC_IP=""
GATEWAY=""
DNS_SERVERS="8.8.8.8 8.8.4.4"

# Models to pull (standard ollama tags)
MODELS_TO_PULL=(
    "qwen2.5-coder:32b"
    "deepseek-r1:32b"
)

# Named aliases exposed to clients.
# Format: "alias_name|base_model_tag|system_prompt"
MODEL_ALIASES=(
    "coder|qwen2.5-coder:32b|You are an expert coding assistant. Provide clean, correct, well-structured code."
    "planner|deepseek-r1:32b|You are a senior technical architect. Think step by step and provide clear, structured plans."
)

# ── END CONFIGURATION ─────────────────────────────────────────────────────────

LOG_FILE="/var/log/llm-server-setup.log"
SCRIPT_START=$(date '+%Y-%m-%d %H:%M:%S')

# Tee everything to log file
exec > >(tee -a "$LOG_FILE") 2>&1

# Colours
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'

log()  { echo -e "${B}[$(date '+%H:%M:%S')]${N} $*"; }
ok()   { echo -e "${G}[$(date '+%H:%M:%S')] ✓${N} $*"; }
warn() { echo -e "${Y}[$(date '+%H:%M:%S')] ⚠${N}  $*"; }
die()  { echo -e "${R}[$(date '+%H:%M:%S')] ✗${N} $*" >&2; exit 1; }
step() { echo -e "\n${B}━━━ $* ━━━${N}"; }


# =============================================================================
# PREFLIGHT
# =============================================================================

preflight() {
    step "Preflight checks"

    [[ $EUID -eq 0 ]] || die "Must be run as root: sudo bash $0"

    # OS check
    if ! grep -qi "fedora" /etc/os-release 2>/dev/null; then
        warn "This script targets Fedora. Detected OS may differ — proceeding anyway."
    else
        local ver
        ver=$(grep VERSION_ID /etc/os-release | cut -d= -f2)
        ok "OS: Fedora $ver"
    fi

    # KFD — AMD GPU compute interface (should be present after normal boot)
    if [[ -c /dev/kfd ]]; then
        ok "/dev/kfd present (AMDGPU driver loaded)"
    else
        warn "/dev/kfd missing. ROCm will not detect the GPU. Try rebooting first."
    fi

    # Strix Halo in lspci
    if lspci 2>/dev/null | grep -qi "Strix Halo"; then
        ok "Strix Halo GPU found in lspci"
    else
        warn "Strix Halo not found in lspci — wrong machine, or driver issue"
    fi

    # RAM (expect ~62 GB visible after BIOS allocates 64 GB to iGPU)
    local ram_gb
    ram_gb=$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)
    ok "System RAM: ${ram_gb} GB"
    (( ram_gb >= 48 )) || warn "Less RAM than expected. Check BIOS iGPU memory allocation."

    # Required tools
    local missing=()
    for cmd in lspci lvm lvextend lvcreate mkfs.xfs nmcli firewall-cmd python3 curl; do
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

    # ── Detect LVM layout ────────────────────────────────────────────────────
    local vg
    vg=$(vgs --noheadings -o vg_name 2>/dev/null | tr -d ' ' | head -1)
    [[ -n "$vg" ]] || die "No LVM volume group found. Is this a default Fedora Server install?"
    log "Volume group: $vg"

    local root_lv="/dev/${vg}/root"
    [[ -b "$root_lv" ]] || die "Expected root LV at $root_lv — not found."

    # ── Grow root LV ─────────────────────────────────────────────────────────
    local current_gb
    current_gb=$(lvs --noheadings --units g -o lv_size "$root_lv" \
                 | tr -d ' <' | sed 's/g.*//')
    current_gb=${current_gb%%.*}   # strip decimals

    if (( current_gb >= 90 )); then
        ok "Root LV already ${current_gb} GB — skipping extension"
    else
        log "Extending root LV: ${current_gb} GB → ${ROOT_LV_SIZE}"
        lvextend -L "${ROOT_LV_SIZE}" "$root_lv" || {
            warn "Could not set exact size (not enough free space?). Using all free space."
            lvextend -l +100%FREE "$root_lv" || true
        }
        # Grow filesystem (XFS on Fedora, ext4 fallback)
        if xfs_growfs / 2>/dev/null; then
            ok "XFS filesystem grown"
        elif resize2fs "$root_lv" 2>/dev/null; then
            ok "ext4 filesystem grown"
        else
            warn "Could not automatically grow filesystem — do it manually."
        fi
    fi

    # ── Create /models LV ────────────────────────────────────────────────────
    local models_lv="/dev/${vg}/models"

    if lvs "$models_lv" &>/dev/null; then
        ok "/models LV already exists"
    else
        local free_gb
        free_gb=$(vgs --noheadings --units g -o vg_free "$vg" \
                  | tr -d ' <' | sed 's/g.*//')
        free_gb=${free_gb%%.*}

        if (( free_gb < 50 )); then
            warn "Only ${free_gb} GB free in VG — skipping /models LV. Pull models to ${MODELS_DIR} anyway."
        else
            log "Creating /models LV (${free_gb} GB available)..."
            lvcreate -l 100%FREE -n models "$vg"
            mkfs.xfs "$models_lv"
            ok "/models LV created (${free_gb} GB)"
        fi
    fi

    # ── Mount /models ─────────────────────────────────────────────────────────
    mkdir -p "${MODELS_DIR}"

    # Add fstab entry if not already there
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
# STEP 3 — ROCm
# =============================================================================

setup_rocm() {
    step "Step 3: ROCm"

    # Already installed?
    if [[ -f /etc/yum.repos.d/rocm.repo ]] && command -v /usr/bin/rocm-smi &>/dev/null; then
        ok "ROCm already installed"
        return
    fi

    log "Writing AMD ROCm repo (RHEL ${ROCM_RHEL_VER} / ROCm ${ROCM_VERSION})..."
    cat > /etc/yum.repos.d/rocm.repo <<REPOEOF
[amdgpu]
name=amdgpu
baseurl=https://repo.radeon.com/amdgpu/${ROCM_VERSION}/rhel/${ROCM_RHEL_VER}/main/x86_64/
enabled=1
priority=50
gpgcheck=1
gpgkey=https://repo.radeon.com/rocm/rocm.gpg.key

[rocm]
name=rocm
baseurl=https://repo.radeon.com/rocm/rhel9/${ROCM_VERSION}/main
enabled=1
priority=50
gpgcheck=1
gpgkey=https://repo.radeon.com/rocm/rocm.gpg.key
REPOEOF

    log "Installing rocminfo and rocm-smi..."
    dnf install -y rocminfo rocm-smi
    ok "ROCm packages installed"

    # Quick GPU detection sanity-check
    local rocminfo_bin
    rocminfo_bin=$(find /opt/rocm*/bin -name rocminfo 2>/dev/null | head -1)
    if [[ -n "$rocminfo_bin" ]]; then
        if HSA_OVERRIDE_GFX_VERSION="${HSA_GFX_OVERRIDE}" "$rocminfo_bin" 2>&1 \
                | grep -q "Device Type.*GPU"; then
            ok "Strix Halo detected by rocminfo (GFX override ${HSA_GFX_OVERRIDE})"
        else
            warn "rocminfo did not detect a GPU agent — Ollama's bundled ROCm may still work"
        fi
    fi
}


# =============================================================================
# STEP 4 — OLLAMA
# =============================================================================

install_ollama() {
    step "Step 4: Ollama"

    if command -v ollama &>/dev/null; then
        ok "Ollama already installed: $(ollama --version 2>/dev/null || echo '(version unknown)')"
        return
    fi

    log "Downloading and installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    ok "Ollama installed"
}


# =============================================================================
# STEP 5 — SERVICE CONFIGURATION
# =============================================================================

configure_ollama_service() {
    step "Step 5: Ollama service configuration"

    mkdir -p /etc/systemd/system/ollama.service.d

    cat > /etc/systemd/system/ollama.service.d/override.conf <<SVCEOF
[Service]
# Bind to all interfaces so LAN clients can reach the API
Environment="OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT}"

# Strix Halo (gfx1151) workaround.
# ROCm does not yet list gfx1151 as a supported target; this alias maps it to
# gfx1100 (RX 7900-class) which has full ROCm support.
# Remove this line once AMD adds official gfx1151 support to ROCm.
Environment="HSA_OVERRIDE_GFX_VERSION=${HSA_GFX_OVERRIDE}"

# Store models on the dedicated storage volume
Environment="OLLAMA_MODELS=${MODELS_DIR}"

# Keep ROCm tools in PATH for rocm-smi / diagnostics
Environment="PATH=/opt/rocm-${ROCM_VERSION}.0/bin:/usr/local/bin:/usr/bin"

# Ensure the ollama process can open the GPU compute and render devices
SupplementaryGroups=render video
SVCEOF

    ok "Service drop-in written"

    # The Ollama installer creates the ollama user; make sure it owns /models
    if id ollama &>/dev/null; then
        chown -R ollama:ollama "${MODELS_DIR}"
        ok "Ownership of ${MODELS_DIR} set to ollama:ollama"
    fi

    systemctl daemon-reload
    systemctl enable ollama
    systemctl restart ollama

    # Give the service a moment to start and discover the GPU
    log "Waiting for Ollama to start..."
    local attempts=0
    while ! curl -sf "http://localhost:${OLLAMA_PORT}/" &>/dev/null; do
        sleep 2
        (( ++attempts > 15 )) && die "Ollama did not become ready after 30 s. Check: journalctl -u ollama -n 30"
    done
    ok "Ollama API is responding"

    # Confirm GPU was picked up
    local gpu_line
    gpu_line=$(journalctl -u ollama --since "1 minute ago" --no-pager -q \
               | grep "inference compute" | tail -1)
    if [[ -n "$gpu_line" ]]; then
        ok "GPU confirmed: $gpu_line"
    else
        warn "GPU not yet visible in logs — may appear after first model load"
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

    # Detect the interface carrying the default route
    local iface
    iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    if [[ -z "$iface" ]]; then
        warn "No default route interface found — skipping static IP"
        return
    fi
    log "Primary interface: $iface"

    # Already static?
    local method
    method=$(nmcli -g ipv4.method con show "$iface" 2>/dev/null || echo "")
    if [[ "$method" == "manual" ]]; then
        local current_addr
        current_addr=$(nmcli -g ipv4.addresses con show "$iface" 2>/dev/null || echo "(unknown)")
        ok "Interface $iface already static: $current_addr"
        return
    fi

    # Auto-detect IP and gateway from DHCP lease if not overridden
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
        # Check if already present
        if python3 - "$model" <<'PYEOF'
import sys, urllib.request, json
model = sys.argv[1]
try:
    with urllib.request.urlopen("http://localhost:11434/api/tags", timeout=5) as r:
        data = json.load(r)
    names = [m["name"] for m in data.get("models", [])]
    # normalise: "qwen2.5-coder:32b" matches "qwen2.5-coder:32b"
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
        python3 - "$model" <<'PYEOF'
import sys, urllib.request, json, time
model = sys.argv[1]
payload = json.dumps({"model": model, "stream": True}).encode()
req = urllib.request.Request(
    "http://localhost:11434/api/pull",
    data=payload,
    headers={"Content-Type": "application/json"},
    method="POST",
)
last_status = ""
try:
    with urllib.request.urlopen(req, timeout=7200) as resp:
        for line in resp:
            try:
                d = json.loads(line)
                status = d.get("status", "")
                completed = d.get("completed", 0)
                total = d.get("total", 0)
                if total and completed:
                    pct = int(completed / total * 100)
                    msg = f"  {status}: {pct}%"
                else:
                    msg = f"  {status}"
                if msg != last_status:
                    print(msg, flush=True)
                    last_status = msg
            except json.JSONDecodeError:
                pass
except Exception as e:
    print(f"Pull failed: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
        ok "$model pulled"
    done
}


# =============================================================================
# STEP 9 — MODEL ALIASES (with capped context window)
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
        OLLAMA_MODELS="${MODELS_DIR}" ollama create "$alias" -f "$modelfile"
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

echo "=== Service ==="
if systemctl is-active --quiet ollama; then
    echo "  ollama: running"
    echo "  listening: $(ss -tlnp 2>/dev/null | awk '/11434/{print $4}' | head -1)"
else
    echo "  ollama: STOPPED"
fi

echo ""
echo "=== GPU (Strix Halo — gfx1100 override) ==="
if command -v rocm-smi &>/dev/null; then
    HSA_OVERRIDE_GFX_VERSION=11.0.0 rocm-smi 2>/dev/null
else
    echo "  rocm-smi not found"
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
        print(f"  {m['name']:<35} {gb:.1f} GB VRAM")
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
    echo "║  Strix Halo · Fedora 43 · Ollama + ROCm                  ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo "  Started: $SCRIPT_START"
    echo "  Log:     $LOG_FILE"
    echo ""

    preflight
    setup_storage
    setup_gpu_groups
    setup_rocm
    install_ollama
    configure_ollama_service
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
    echo "  Service logs:  journalctl -fu ollama"
    echo "  Full log:      $LOG_FILE"
    echo ""
    echo "  Example (from any LAN machine):"
    echo "    curl http://${server_ip}:${OLLAMA_PORT}/api/generate \\"
    echo "      -d '{\"model\":\"coder\",\"prompt\":\"hello\",\"stream\":false}'"
    echo ""

    ollama-status
}

main "$@"
