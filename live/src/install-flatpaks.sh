#!/usr/bin/bash
# Pre-install flatpaks into the live squashfs.
#
# Uses --mount=type=cache,target=/var/cache/flatpak-dl to persist the flatpak
# ostree repo across builds.  On each run the script:
#   1. Seeds /var/lib/flatpak/repo from the build cache (warm start)
#   2. Reconciles to match /tmp/flatpaks-list (only deltas downloaded)
#   3. Saves the repo back to the cache for next build
#
# /tmp/flatpaks-list is COPYd by the Containerfile so it's always current.
# Requires network at build time; CAP_SYS_ADMIN for dbus.

set -exo pipefail

FLATPAK_CACHE="/var/cache/flatpak-dl"

# overlayfs inside Podman builds doesn't support O_TMPFILE.  /dev/shm would
# work but is only ~3.5 GB on GHA 7-GB runners — too small for GNOME Platform.
# The --mount=type=cache volume is a bind-mount from btrfs (supports O_TMPFILE)
# and has ~60 GB free, so use a subdirectory of it as TMPDIR instead.
mkdir -p "${FLATPAK_CACHE}/tmp"
export TMPDIR="${FLATPAK_CACHE}/tmp"
mkdir -p /run/dbus
dbus-daemon --system --fork --nopidfile
sleep 1

# ── Seed flatpak repo from build cache (warm start) ──────────────────────────
if [ -d "${FLATPAK_CACHE}/repo/refs" ]; then
    echo "Seeding flatpak repo from build cache..."
    rsync -a --ignore-existing "${FLATPAK_CACHE}/repo/" /var/lib/flatpak/repo/ || true
    echo "Cache seed complete"
fi

flatpak remote-add --system --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo

# bootc-installer bundle.
# Upstream publishes the installer x86_64-only. For aarch64 we build it from
# source on an arm runner (dakota-iso build-installer-aarch64.yml) and publish
# the bundle to the installer-aarch64 release, then fetch it here so the live ISO
# ships a working GUI installer on Apple Silicon too. Unsupported arches fall
# back to CLI install ('bootc install to-disk').
#
# INSTALLER_CHANNEL controls which x86_64 release to pull from:
#   stable (default) → GitHub "latest" release (non-pre-release)
#   dev              → latest-dev rolling pre-release (tracks dev branch)
ARCH="$(flatpak --default-arch)"
FLATPAK_FILENAME="org.bootcinstaller.Installer.flatpak"
INSTALLER_APP_ID="org.bootcinstaller.Installer"
if [[ "${INSTALLER_CHANNEL:-stable}" == "dev" ]]; then
    FLATPAK_FILENAME="org.bootcinstaller.Installer.Devel.flatpak"
    INSTALLER_APP_ID="org.bootcinstaller.Installer.Devel"
fi

INSTALL_INSTALLER=1
case "${ARCH}" in
  x86_64)
    # Primary: projectbluefin/bootc-installer. Fallback: tuna-os/tuna-installer.
    INSTALLER_REPO="projectbluefin/bootc-installer"
    FALLBACK_REPO="tuna-os/tuna-installer"
    if [[ "${INSTALLER_CHANNEL:-stable}" == "dev" ]]; then
        PRIMARY_URL="https://github.com/${INSTALLER_REPO}/releases/download/latest-dev/${FLATPAK_FILENAME}"
        FALLBACK_URL="https://github.com/${FALLBACK_REPO}/releases/download/continuous-dev/${FLATPAK_FILENAME}"
    else
        PRIMARY_URL="https://github.com/${INSTALLER_REPO}/releases/latest/download/${FLATPAK_FILENAME}"
        FALLBACK_URL="https://github.com/${FALLBACK_REPO}/releases/latest/download/${FLATPAK_FILENAME}"
    fi
    ;;
  aarch64)
    # Built from source (see dakota-iso build-installer-aarch64.yml). Only the
    # stable app ID is produced for aarch64; INSTALLER_AARCH64_URL overrides the
    # default fork release location.
    INSTALLER_APP_ID="org.bootcinstaller.Installer"
    PRIMARY_URL="${INSTALLER_AARCH64_URL:-https://github.com/T-Py-T/dakota-iso/releases/download/installer-aarch64/org.bootcinstaller.Installer.flatpak}"
    FALLBACK_URL="${PRIMARY_URL}"
    ;;
  *)
    INSTALL_INSTALLER=0
    echo "WARNING: no bootc-installer Flatpak for ${ARCH}; building live ISO without the GUI installer." >&2
    echo "WARNING: install Dakota from a terminal with: sudo bootc install to-disk" >&2
    ;;
esac

if [[ "${INSTALL_INSTALLER}" == "1" ]]; then
    if ! curl --retry 3 --fail --location \
        "${PRIMARY_URL}" \
        -o /tmp/tuna-installer.flatpak 2>/dev/null; then
        echo "Primary installer source unavailable, falling back..."
        curl --retry 3 --fail --location \
            "${FALLBACK_URL}" \
            -o /tmp/tuna-installer.flatpak
    fi

    # Import the bundle into a temporary local repo and install from there.
    # flatpak install --bundle in a container build (no running flatpak system
    # daemon) only creates the installer-origin: remote ref — it does NOT create
    # the deploy/ ref that flatpak run/list require.  Installing from a local
    # file:// remote goes through the full deploy pipeline and correctly creates
    # the deploy/ ref so the app is visible and runnable.
    INSTALLER_LOCAL_REPO="/tmp/installer-local-repo"
    ostree init --repo="${INSTALLER_LOCAL_REPO}" --mode=archive-z2
    flatpak build-import-bundle "${INSTALLER_LOCAL_REPO}" /tmp/tuna-installer.flatpak
    rm -f /tmp/tuna-installer.flatpak
    flatpak remote-add --system --no-gpg-verify installer-local "file://${INSTALLER_LOCAL_REPO}"
    flatpak install --system --noninteractive installer-local "${INSTALLER_APP_ID}" || \
        flatpak update --system --noninteractive "${INSTALLER_APP_ID}"
    flatpak remote-delete --system --force installer-local || true
    rm -rf "${INSTALLER_LOCAL_REPO}"

    # flatpak install inside a container build (no flatpak-system-helper daemon)
    # creates the deployment directory but omits the 'active' symlink inside the
    # branch directory, leaving the app unreachable to 'flatpak run'/'flatpak list'.
    # Reproduce the symlink that a normal installation would create.
    _app_arch_dir="/var/lib/flatpak/app/${INSTALLER_APP_ID}/${ARCH}"
    for _branch_dir in "${_app_arch_dir}"/*/; do
        _branch_dir="${_branch_dir%/}"
        [[ -d "${_branch_dir}" ]] || continue
        if [[ ! -L "${_branch_dir}/active" ]]; then
            # Find the single deployment hash directory
            _hash=$(find "${_branch_dir}" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | head -1)
            if [[ -n "${_hash}" ]]; then
                ln -sfn "${_hash}" "${_branch_dir}/active"
                echo "Created active symlink: ${_branch_dir}/active → ${_hash}"
            fi
        fi
    done

    flatpak override --system --filesystem=/etc:ro "${INSTALLER_APP_ID}"
fi

# ── Reconcile Flathub apps against the wanted list ───────────────────────────
# In debug mode, skip the full Flathub app list to keep builds fast.
# NOTE: Disabled to allow debug ISOs with full flatpak suite + SSH access
# if [[ "${DEBUG:-0}" == "1" ]]; then
#     echo "DEBUG mode: skipping Flathub app list (installer-only ISO)"
#     # Still save cache for the installer runtime
#     echo "Saving flatpak repo to build cache..."
#     mkdir -p "${FLATPAK_CACHE}"
#     rsync -a --delete /var/lib/flatpak/repo/ "${FLATPAK_CACHE}/repo/"
#     exit 0
# fi

readarray -t WANTED < <(grep -v '^[[:space:]]*#' /tmp/flatpaks-list | grep -v '^[[:space:]]*$')

# Install or update everything in the list (--or-update = skip if current)
# --no-related skips locale packs and debug symbols (~3 GB uncompressed)
# Batch install first (fast path, x86_64). If it fails because an app has no
# build for this arch (e.g. some apps lack aarch64 on Flathub), fall back to
# best-effort per-app install so a single missing app does not abort the build.
if ! flatpak install --system --noninteractive --no-related --or-update flathub "${WANTED[@]}"; then
    echo "Batch flatpak install failed; retrying per-app (best effort for $(flatpak --default-arch))..." >&2
    for app in "${WANTED[@]}"; do
        flatpak install --system --noninteractive --no-related --or-update flathub "$app" \
            || echo "WARNING: skipping ${app} (no build for $(flatpak --default-arch)?)" >&2
    done
fi

# Remove any system app that is no longer in the wanted list
readarray -t INSTALLED < <(flatpak list --app --system --columns=application 2>/dev/null || true)
for app in "${INSTALLED[@]}"; do
    # Keep the installer regardless (stable or devel app ID)
    [[ "$app" == "org.bootcinstaller.Installer" ]] && continue
    [[ "$app" == "org.bootcinstaller.Installer.Devel" ]] && continue
    if [[ ! " ${WANTED[*]} " == *" ${app} "* ]]; then
        echo "Removing dropped flatpak: $app"
        flatpak uninstall --system --noninteractive "$app" || true
    fi
done

# Prune unused runtimes left behind by removals
flatpak uninstall --system --noninteractive --unused || true

# ── Save flatpak repo to build cache for next build ──────────────────────────
echo "Saving flatpak repo to build cache..."
mkdir -p "${FLATPAK_CACHE}"
rsync -a --delete /var/lib/flatpak/repo/ "${FLATPAK_CACHE}/repo/"
echo "Cache updated"
