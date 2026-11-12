<p align="center">
  <a href="https://openimages.cloud/images/trove-guest-image/">
    <img src="https://openimages.cloud/img/og/trove-guest-image.png" alt="Trove guest image for OpenStack" width="720">
  </a>
</p>

<p align="center">
  <a href="https://openimages.cloud/images/trove-guest-image/"><img alt="Latest version" src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fimages.openimages.cloud%2Ftrove-guest-image%2Flatest%2FMANIFEST.json&query=%24.version&label=latest&color=2459c4&cacheSeconds=3600"></a>
  <a href="https://github.com/open-img-cloud/trove-guest-image/actions/workflows/release.yml"><img alt="Release" src="https://github.com/open-img-cloud/trove-guest-image/actions/workflows/release.yml/badge.svg"></a>
  <a href="https://openimages.cloud/verify/"><img alt="Signed with Sigstore cosign" src="https://img.shields.io/badge/signed-Sigstore%20cosign-2459c4"></a>
  <a href="LICENSE"><img alt="License GPL-2.0" src="https://img.shields.io/badge/license-GPL--2.0-555"></a>
</p>

<p align="center">
  <a href="https://openimages.cloud/images/trove-guest-image/"><b>Catalog page</b></a> ·
  <a href="https://images.openimages.cloud/trove-guest-image/latest/">Download</a> ·
  <a href="https://openimages.cloud/verify/">Verify</a> ·
  <a href="https://github.com/open-img-cloud/docs">Documentation</a> ·
  <a href="https://github.com/open-img-cloud/trove-guest-image/issues">Report an issue</a>
</p>

Trove guest image (qcow2) for **OpenStack Trove** (Database as a Service): the image Trove
boots for each database instance, carrying the Trove guest agent and Docker CE, built per
OpenStack series from [`openstack/trove`](https://opendev.org/openstack/trove) with
[diskimage-builder](https://docs.openstack.org/diskimage-builder/) and signed with Sigstore
cosign, like every [openimages.cloud](https://openimages.cloud) image. It is an **OpenStack
control plane component**: Trove boots it, tenants never do.

## At a glance

| | |
|---|---|
| **Upstream** | `openstack/trove` elements and guest agent at a pinned `stable/<series>` commit, built like upstream's production image (`trovestack build-image`, `dev_mode=false`) |
| **Guest OS** | Ubuntu 24.04 (noble) minimal, the release upstream builds, tests and publishes for these series |
| **User** | `ubuntu`, SSH key only (Nova key pair), passwordless `sudo`, root login disabled |
| **Services** | `guest-agent` (runs as `ubuntu`, `--config-dir=/etc/trove/conf.d`), `docker`, `docker-hostnic.socket` |
| **Format** | qcow2, x86_64, 5 GiB virtual size grown to the flavor disk by cloud-init, `trove-guest-image-<series>-amd64.qcow2` |
| **Version** | OpenStack series, e.g. `2026.2` ([all versions](https://images.openimages.cloud/trove-guest-image/versions.json)) |

| OpenStack series | Codename | Trove branch | Status here |
|---|---|---|---|
| 2025.2 | Flamingo | stable/2025.2 | buildable |
| 2026.1 | Gazpacho | stable/2026.1 | buildable |
| 2026.2 | Hibiscus | stable/2026.2 | published, `latest/` |

The series selects the pinned Trove commit, hence the guest agent version: the guest agent must
match the Trove control plane, so use the image of your series.

## Quick start

```sh
# Latest series and its file name, from the signed manifest
M=https://images.openimages.cloud/trove-guest-image/latest/MANIFEST.json
V=$(curl -fsS $M | jq -r .version); F=$(curl -fsS $M | jq -r .filename)
curl -fLO https://images.openimages.cloud/trove-guest-image/$V/$F
```

<details>
<summary><b>OpenStack (Trove operators)</b></summary>

```sh
openstack image create trove-guest-image-$V \
  --private --disk-format qcow2 --container-format bare \
  --property hw_rng_model=virtio \
  --tag trove \
  --file "$F"

# One image for every datastore version, selected by tag:
openstack datastore version create 8.4 mysql mysql "" \
  --image-tags trove --active --default
```

Then in `trove.conf`:

```ini
[DEFAULT]
# Key pair injected into every database instance (the only way in).
nova_keypair = trove-mgmt
# Network the guest agent uses to reach the message queue.
management_networks = <trove management network id>
```

The datastore images come from `docker_image` / `backup_docker_image` in
`trove-guestagent.conf` (upstream defaults: `quay.io/openstack.trove/*`); the guests must reach
that registry. Upstream reference:
[building guest images](https://docs.openstack.org/trove/latest/admin/building_guest_images.html)
and [running Trove in production](https://docs.openstack.org/trove/latest/admin/run_trove_in_production.html).

</details>

<details>
<summary><b>SSH access and configuration</b></summary>

cloud-init installs the key of the Nova key pair Trove passes at boot (`nova_keypair` in
`trove.conf`); the `ubuntu` password is locked and SSH accepts keys only. cloud-init reads the
`ConfigDrive` and `OpenStack` (metadata service) datasources, through which Trove injects
`/etc/trove/conf.d/guest_info.conf` and `trove-guestagent.conf`.

</details>

<details>
<summary><b>Verify the signature</b></summary>

```sh
curl -fLO https://images.openimages.cloud/trove-guest-image/$V/$F.bundle
cosign verify-blob "$F" --bundle "$F.bundle" \
  --certificate-identity-regexp '^https://github.com/open-img-cloud/\.github/\.github/workflows/build-(libguestfs|dib|nix-flake|freebsd)-image\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The certificate identity is the shared DIB build workflow; `MANIFEST.json` ties the file to
this repository's commit and build run.

</details>

## What this image changes

The image is Ubuntu minimal noble plus the upstream elements `base`, `vm`, `ubuntu-minimal`,
`cloud-init-datasources` (`ConfigDrive, OpenStack`), `guest-agent` (agent installed from source
in `/opt/guest-agent-venv`, `guest-agent.service`, `docker-hostnic` network plugin) and
`ubuntu-docker` (Docker CE from download.docker.com). Differences from upstream:

- **No password.** Upstream's `ubuntu-guest` element creates the `ubuntu` user with the
  password `ubuntu`. Here that password (and root's) is replaced by a locked hash and SSH
  accepts keys only (local element [`elements/oic-trove-guest`](elements/oic-trove-guest)).
- **Pinned inputs.** Per series, `build/dib-build.sh` pins the `openstack/trove` commit
  (elements and guest agent code), the `openstack/requirements` commit (upper-constraints for
  diskimage-builder and every guest agent dependency) and the Docker CE / containerd.io
  versions. It fails if upstream's element list drifts from ours, or if apt installs another
  Docker version.
- **Never a dev image.** `dev_mode=true` images make the guest pull the agent code from the
  controller over SSH; they are for Trove developers only and are not built here.
- Left out: `openstack-ci-mirrors` and `pip-cache` (upstream CI only), `root-passwd` (only
  used when a root password is requested).

No datastore container is embedded (`DIB_TROVE_DOCKER_IMAGES`, new in 2026.2, is left empty):
the image stays generic and the operator chooses the registry and the datastore versions. The
image is about 1.4 GB, like upstream's noble image: Docker CE and the guest agent virtualenv
cannot be dropped, so it exceeds the 1 GB target of the image standards on purpose.

## How it is validated

This image is **not boot-tested** by openimages.cloud yet: outside Trove the guest agent
restarts in a loop (no injected configuration), and the network stack (ifupdown and
isc-dhcp-client come with the upstream `guest-agent` element) has not been checked against
the strict IPv6 contract. Each release is:

- built from the pinned inputs, with guards against element drift and an unexpected Docker
  version;
- checksummed and signed with Sigstore cosign (keyless);
- validated after publication from the CDN: `MANIFEST.json` and its required keys, sidecar
  files, cache headers, size limit, and `cosign verify-blob` on the downloaded file.

Known upstream behaviour on 2026.x non-dev images: `trove-image-loader.service` fails at boot
(it reads `/etc/trove/controller.conf`, which only exists in devstack); it is harmless, the
guest agent pulls its images itself.

Planned check, closer to what Trove does: boot it with a key pair and config drive files
mimicking Trove's injection, SSH in as `ubuntu`, then assert `sudo -n true`, a locked password
(`passwd -S ubuntu`), password authentication refused, `docker info` working with the pinned
version, `guest-agent.service` started and logging its connection attempt to the message
queue. A full check needs a Trove control plane (devstack with the image registered).

## How releases happen

1. Every day at 07:23 UTC a watcher looks for a new Trove `stable/YYYY.N` branch and opens a
   pull request that bumps [`VERSION`](VERSION). Before merging it, add the pinned `TROVE_REF`
   and `REQ_REF` of that series to `build/dib-build.sh` (the build refuses a series without
   pins).
2. Merging it is all it takes: the release is tagged, built, signed and published, then
   `latest/` and the [catalog](https://openimages.cloud/images/) move to it.
3. An older series can be rebuilt with `release.yml` (`workflow_dispatch`, `version` input):
   `latest/` only follows the newest series. `sync-latest.yml` points `latest/` to an already
   published series without rebuilding.
4. When a stable branch gets relevant fixes (or for a Docker CE update), bump the pins in
   `build/dib-build.sh` by pull request, then republish.

The build runs `build/dib-build.sh` in a privileged `ubuntu:24.04` container on a
GitHub-hosted runner (debootstrap needs full root capabilities). That container is not
signed by this project, so the builder signature check of the other images is off here.

This repository only holds what is specific to this image: [`VERSION`](VERSION),
[`build/dib-build.sh`](build/dib-build.sh), [`build/detect-upstream.sh`](build/detect-upstream.sh),
the [`elements/oic-trove-guest`](elements/oic-trove-guest) DIB element and thin workflows
calling the shared pipeline in [`open-img-cloud/.github`](https://github.com/open-img-cloud/.github).

## License

The build tooling in this repository is under [GPL-2.0](LICENSE). The image content keeps its
own licenses (Trove and diskimage-builder are Apache-2.0, Docker CE is Apache-2.0, Ubuntu
packages under their respective licenses). OpenStack is a trademark of the Open
Infrastructure Foundation; this project is not affiliated with it.
