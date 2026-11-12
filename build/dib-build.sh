#!/usr/bin/env bash
# DIB build hook called by the build-dib-image reusable workflow.
# Receives: $1 = output dir, $2 = version (OpenStack series, e.g. "2026.2").
# Must produce: $1/trove-guest-image-${version}-amd64.qcow2
#
# Builds the OpenStack Trove guest image the way upstream does in
# `integration/scripts/trovestack build-image ubuntu noble false ubuntu`
# (function build_guest_image in integration/scripts/functions_qemu), i.e. the
# production (dev_mode=false) image published daily by the upstream job
# `publish-trove-guest-image-ubuntu-noble` on tarballs.opendev.org:
# Ubuntu minimal noble, cloud-init, Docker CE, and the trove guest agent
# installed from source in /opt/guest-agent-venv. Datastores (MySQL, MariaDB,
# PostgreSQL, ...) are NOT in the image: the guest agent pulls their container
# images at instance creation, as configured by the operator (docker_image).
#
# We call `disk-image-create` directly instead of `trovestack build-image`
# because trovestack installs host packages with sudo, rebuilds its own venv
# with an unpinned diskimage-builder, and only knows branch names. To stay in
# sync with upstream, the script reads the element list from the pinned
# functions_qemu and fails if it no longer matches ours.
#
# Differences from upstream (see README):
#   - pinned trove commit, requirements commit and Docker CE version per
#     series, instead of branch heads and whatever is current at build time;
#   - local element oic-trove-guest: key-only SSH (upstream's ubuntu-guest
#     element gives the `ubuntu` user the password "ubuntu");
#   - no openstack-ci-mirrors / pip-cache (CI-only elements), no root-passwd.
#
# Container expected: ubuntu:24.04 (debootstrap for the ubuntu-minimal
# element), privileged, as root. See release.yml.

set -euo pipefail

OUT_DIR="${1:?usage: dib-build.sh <output-dir> <version>}"
VERSION="${2:?usage: dib-build.sh <output-dir> <version>}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Pins per OpenStack series (edit here: the workflow does not forward env)
# TROVE_REF: commit of opendev.org/openstack/trove stable/<series>. It provides
#   both the DIB elements (integration/scripts/files/elements) and the guest
#   agent code baked into the image.
# REQ_REF: commit of opendev.org/openstack/requirements stable/<series>. Its
#   upper-constraints.txt pins diskimage-builder on the build host and every
#   Python dependency of the guest agent.
# Bump both by pull request (git ls-remote <repo> refs/heads/stable/<series>),
# then republish. A series missing here fails the build on purpose: a new
# series detected by watch.yml needs a reviewed pin first.
case "$VERSION" in
  2025.2)
    TROVE_REF=95f656d8078fcaa41723da83ed5704b9bbbab797   # stable/2025.2, 2026-08-15
    REQ_REF=a677fd2b8eacd60bafcff4bf69930854a7057903     # stable/2025.2, 2026-11-10
    ;;
  2026.1)
    TROVE_REF=fc7ce52e189eed36dd4e1d7116f9d75bb89bcaae   # stable/2026.1, 2026-09-22
    REQ_REF=e67312b6360a9da57677e07e0fb57abbfa28bca0     # stable/2026.1, 2026-11-02
    ;;
  2026.2)
    TROVE_REF=9291049637561a8a1a51c2a5dfe2743c51fccdbf   # stable/2026.2, 2026-10-05
    REQ_REF=bbeadfcdd6cd8ac9abf888661d3fc65fa45c7480     # stable/2026.2, 2026-11-02
    ;;
  *)
    if [[ ! "$VERSION" =~ ^[0-9]{4}\.[0-9]+$ ]]; then
      echo "::error::version '$VERSION' is not an OpenStack series (YYYY.N)" >&2
    else
      echo "::error::no pinned trove/requirements commits for series $VERSION; add them to build/dib-build.sh" >&2
    fi
    exit 1
    ;;
esac

TROVE_REPO="https://opendev.org/openstack/trove.git"
UPPER_CONSTRAINTS_URL="https://opendev.org/openstack/requirements/raw/commit/${REQ_REF}/upper-constraints.txt"

# Guest OS: what upstream builds, tests (devstack TROVE_IMAGE_OS_RELEASE) and
# publishes for every maintained series. The Docker CE pin below is tied to it.
GUEST_OS="ubuntu"
GUEST_RELEASE="noble"
GUEST_USERNAME="ubuntu"   # trovestack default; the guest agent runs as this user
IMAGE_ARCH="amd64"
IMAGE_SIZE_GB="5"         # trovestack GUEST_IMAGESIZE default

# Docker CE from download.docker.com (installed by upstream's ubuntu-docker
# element, unpinned there). Pinned through apt preferences by our element
# oic-trove-guest; the build fails if apt installs anything else.
DOCKER_VERSION="5:29.9.3-1~ubuntu.24.04~noble"
CONTAINERD_VERSION="2.4.2-3~ubuntu.24.04~noble"

# Elements upstream's build_guest_image passes (dev_mode=false, no root
# password), and the ones we deliberately leave out.
UPSTREAM_EXPECTED=( base vm ubuntu-minimal cloud-init-datasources pip-cache guest-agent ubuntu-docker root-passwd )
UPSTREAM_SKIPPED=( openstack-ci-mirrors pip-cache root-passwd )
OUR_ELEMENTS=( base vm ubuntu-minimal cloud-init-datasources guest-agent ubuntu-docker oic-trove-guest )

echo "[dib-build] out_dir=$OUT_DIR version=$VERSION trove_ref=$TROVE_REF requirements_ref=$REQ_REF"
echo "[dib-build] guest=$GUEST_OS-$GUEST_RELEASE arch=$IMAGE_ARCH docker=$DOCKER_VERSION containerd=$CONTAINERD_VERSION"

# --- Build prerequisites (Ubuntu container, running as root) --------------
# jq is not used here but by the shared MANIFEST.json step that runs next in
# the same container.
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  qemu-utils git kpartx debootstrap squashfs-tools python3-venv python3-pip \
  ca-certificates jq curl xz-utils e2fsprogs dosfstools sudo gdisk util-linux

# --- trove at the pinned commit -------------------------------------------
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Full clone: DIB's source-repositories element re-clones this checkout as
# the guest-agent source and must find the pinned commit on a branch.
git clone -q --no-checkout "$TROVE_REPO" "$work/trove"
git -C "$work/trove" checkout -q -B oic-pinned "$TROVE_REF"
if [[ "$(git -C "$work/trove" rev-parse HEAD)" != "$TROVE_REF" ]]; then
  echo "::error::trove checkout is not at $TROVE_REF" >&2
  exit 1
fi
echo "[dib-build] trove $(git -C "$work/trove" log -1 --format='%H %cs %s')"

# Drift guard: upstream's build_guest_image must still use the same elements.
fq="$work/trove/integration/scripts/functions_qemu"
# shellcheck disable=SC2016  # literal $elementes / ${guest_os} from upstream's source
mapfile -t up_elements < <(
  sed -nE 's/^\s*(local )?elementes="(\$elementes )?([^"]*)"\s*$/\3/p' "$fq" \
    | sed 's/\${guest_os}/ubuntu/' | tr ' ' '\n' | sed '/^$/d')
up_filtered=()
for e in "${up_elements[@]}"; do
  [[ "$e" == openstack-ci-mirrors ]] || up_filtered+=( "$e" )
done
if [[ "${up_filtered[*]}" != "${UPSTREAM_EXPECTED[*]}" ]]; then
  echo "::error::upstream build_guest_image elements changed: '${up_elements[*]}' (expected '${UPSTREAM_EXPECTED[*]}' plus optional openstack-ci-mirrors); review dib-build.sh" >&2
  exit 1
fi
echo "[dib-build] upstream elements: ${up_elements[*]} (skipped here: ${UPSTREAM_SKIPPED[*]})"

# The guest agent element must still take its code from trove itself.
if ! grep -qE '^guest-agent git /opt/guest-agent https://opendev.org/openstack/trove ' \
     "$work/trove/integration/scripts/files/elements/guest-agent/source-repository-guest-agent"; then
  echo "::error::upstream guest-agent source-repository changed; review dib-build.sh" >&2
  exit 1
fi

# --- diskimage-builder in a venv, constrained by the series ---------------
python3 -m venv "$work/venv"
# shellcheck source=/dev/null
. "$work/venv/bin/activate"
pip install --upgrade pip
pip install -c "$UPPER_CONSTRAINTS_URL" diskimage-builder
echo "[dib-build] $(disk-image-create --version 2>&1 | tail -n1)"

# --- Environment, as set by build_guest_image (dev_mode=false) -------------
export ELEMENTS_PATH="$work/trove/integration/scripts/files/elements:$REPO_DIR/elements"
export DIB_RELEASE="$GUEST_RELEASE"
export DISTRO_NAME="$GUEST_OS"
export DIB_CLOUD_INIT_ETC_HOSTS="localhost"
export DIB_CLOUD_INIT_DATASOURCES="ConfigDrive, OpenStack"
export GUEST_USERNAME
export HOST_SCP_USERNAME="none"   # only used in dev mode
export DEV_MODE="false"
export SYNC_LOG_TO_CONTROLLER="False"
# Guest agent code and Python constraints at the pinned commits instead of
# the stable branch heads named in source-repository-guest-agent.
export DIB_REPOLOCATION_guest_agent="$work/trove"
export DIB_REPOREF_guest_agent="$TROVE_REF"
export DIB_REPOLOCATION_upper_constraints="$UPPER_CONSTRAINTS_URL"
# Read by elements/oic-trove-guest.
export DIB_OIC_DOCKER_VERSION="$DOCKER_VERSION"
export DIB_OIC_CONTAINERD_VERSION="$CONTAINERD_VERSION"

# Same debootstrap workaround as octavia-amphora and manila-service-image:
# minbase lacks gpgv, which the in-chroot `apt-get update` needs.
export DIB_DEBOOTSTRAP_EXTRA_ARGS='--include=gpgv,gnupg2,ca-certificates'
rm -rf "$HOME/.cache/image-create" || true

cd "$work"
CMD=( disk-image-create -a "$IMAGE_ARCH" -t qcow2 -o trove-guest-image
      --image-size "$IMAGE_SIZE_GB" "${OUR_ELEMENTS[@]}" )
echo "[dib-build] running: ${CMD[*]}"
"${CMD[@]}"

# --- Hand the qcow2 to the workflow ----------------------------------------
final="${OUT_DIR}/trove-guest-image-${VERSION}-${IMAGE_ARCH}.qcow2"
mv trove-guest-image.qcow2 "$final"
echo "[dib-build] produced $final"
ls -lh "$final"
