# Trove guest image cloud images

Signed guest images for **OpenStack Trove** (Database as a Service), built
per OpenStack series, part of the [openimages.cloud](https://openimages.cloud)
catalog.

- Catalog page: <https://openimages.cloud/images/trove-guest-image/>
- Registry: <https://images.openimages.cloud/trove-guest-image/latest/>

## About

Trove creates one Nova instance per database instance, booted from a
**guest image** registered in Glance. Since Victoria a single image serves
every datastore: the image carries the **Trove guest agent** (a Python
service, from the `openstack/trove` tree) and **Docker CE**; the database
itself (MySQL, MariaDB, PostgreSQL, ...) runs in a container that the guest
agent pulls at instance creation from the registry the operator configures
(`docker_image`, `backup_docker_image`). Like
[`octavia-amphora`][octavia] and [`manila-service-image`][manila], this is an
**OpenStack control plane component**: Trove boots it, tenants never do.

Upstream builds it with [diskimage-builder][dib] through
`integration/scripts/trovestack build-image` and publishes a non-dev
Ubuntu noble image of master every day on [tarballs.opendev.org][tarballs].
This repo builds the same image (`dev_mode=false`) for each maintained
stable series: Ubuntu minimal noble plus the upstream elements `base`, `vm`,
`ubuntu-minimal`, `cloud-init-datasources` (`ConfigDrive, OpenStack`),
`guest-agent` (agent installed from source in `/opt/guest-agent-venv`,
`guest-agent.service`, `docker-hostnic` network plugin) and `ubuntu-docker`
(Docker CE from download.docker.com). It then signs it with cosign
(keyless) and publishes it through the shared openimages.cloud pipeline.
Differences from upstream:

- **No password.** Upstream's `ubuntu-guest` element creates the `ubuntu`
  user with the password `ubuntu`. Here that password (and root's) is
  replaced by a locked hash and SSH accepts keys only (local element
  `elements/oic-trove-guest`).
- **Pinned inputs.** Per series, `build/dib-build.sh` pins the
  `openstack/trove` commit (elements and guest agent code), the
  `openstack/requirements` commit (upper-constraints for diskimage-builder
  and every guest agent dependency) and the Docker CE / containerd.io
  versions, instead of branch heads and whatever is current at build time.
  It fails if upstream's element list drifts from ours, or if apt installs
  another Docker version.
- **Never a dev image.** `dev_mode=true` images make the guest pull the
  agent code from the controller over SSH; they are for Trove developers
  only and are not built here.
- Left out: `openstack-ci-mirrors` and `pip-cache` (upstream CI only),
  `root-passwd` (only used when a root password is requested).

No datastore container is embedded (`DIB_TROVE_DOCKER_IMAGES`, new in
2026.2, is left empty): the image stays generic and the operator chooses the
registry and the datastore versions.

The build pipeline is shared with the rest of
[`open-img-cloud`](https://github.com/open-img-cloud): this repo only ships
`VERSION`, `build/dib-build.sh`, `build/detect-upstream.sh`, one small DIB
element and thin caller workflows that delegate to the reusable workflows in
[`open-img-cloud/.github`](https://github.com/open-img-cloud/.github) (`@main`).

## Versioning

`<version>` is the **OpenStack series** (e.g. `2026.2`). It selects the
pinned `stable/<series>` commit of Trove, hence the guest agent version: the
guest agent must match the Trove control plane, so use the image of your
series.

| OpenStack series | Codename | Trove branch  | Status here |
|------------------|----------|---------------|-------------|
| 2025.2           | Flamingo | stable/2025.2 | buildable   |
| 2026.1           | Gazpacho | stable/2026.1 | buildable   |
| 2026.2           | Hibiscus | stable/2026.2 | default     |

Guest OS: Ubuntu 24.04 (noble), the release upstream builds, tests (devstack
`TROVE_IMAGE_OS_RELEASE`) and publishes for all these series. Upstream's
`trovestack` default and its "building guest images" page still say jammy;
the gate moved to noble.

## Image

- File: `trove-guest-image-<version>-amd64.qcow2` (e.g.
  `trove-guest-image-2026.2-amd64.qcow2`), 5 GiB virtual size, grown to the
  flavor disk by cloud-init at first boot. Expected size around 1.4 GB, like
  upstream's noble image: Docker CE and the guest agent virtualenv cannot be
  dropped, so the image exceeds the 1 GB target of the image standards
  (section H) on purpose.
- User: `ubuntu`, passwordless sudo (the guest agent needs it), **no
  password**. cloud-init installs the key of the Nova key pair Trove passes
  at boot (`nova_keypair` in `trove.conf`). Root login is disabled.
- cloud-init datasources: `ConfigDrive`, `OpenStack` (metadata service).
  Trove injects `/etc/trove/conf.d/guest_info.conf` and
  `trove-guestagent.conf` through it.
- Services: `guest-agent` (runs as `ubuntu`, `--config-dir=/etc/trove/conf.d`),
  `docker`, `docker-hostnic.socket`.

## Use it (Trove operators)

```sh
V=2026.2
curl -fLO https://images.openimages.cloud/trove-guest-image/$V/trove-guest-image-$V-amd64.qcow2

openstack image create trove-guest-image-$V \
    --private --disk-format qcow2 --container-format bare \
    --property hw_rng_model=virtio \
    --tag trove \
    --file trove-guest-image-$V-amd64.qcow2

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
`trove-guestagent.conf` (upstream defaults: `quay.io/openstack.trove/*`); the
guests must reach that registry. Upstream reference:
[building guest images][build] and [running Trove in production][prod].

## Verify before deploy

```sh
sha256sum -c <filename>.sha256
cosign verify-blob \
    --bundle <filename>.bundle \
    --new-bundle-format \
    --certificate-identity-regexp '^https://github.com/open-img-cloud/\.github/\.github/workflows/build-dib-image\.yml@' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    <filename>
```

The certificate identity is the reusable DIB workflow in
`open-img-cloud/.github`; `MANIFEST.json` ties the artifact to this repo's
commit and build run. More in the [verification guide](https://openimages.cloud/verify/).

## Release flow

1. `watch.yml` runs daily (07:23 UTC) and opens an `auto/upstream-bump` pull
   request when Trove gets a new `stable/YYYY.N` branch. Before merging it,
   add the pinned `TROVE_REF` and `REQ_REF` of that series to
   `build/dib-build.sh` (the build refuses a series without pins).
2. Merge, then push the tag `v<VERSION>`: `release.yml` calls
   `build-dib-image.yml@main`, which runs `build/dib-build.sh` in a privileged
   `ubuntu:24.04` container on a GitHub-hosted runner, signs and publishes the
   image (versioned path, `latest/`, `versions.json`).
3. An older series can be rebuilt with `workflow_dispatch` (`version` input):
   `latest/` only moves for the newest series. `sync-latest.yml` repoints
   `latest/` to an already published version without rebuilding.
4. When a stable branch gets relevant fixes (or for a Docker CE update), bump
   the pins in `build/dib-build.sh` by pull request, then republish.

## Testing

No runtime smoke yet (`runtime_smoke_login_user` is unset). The image is
cloud-init based and may well pass the shared contract as `ubuntu`, but it
has not been tried: outside Trove the guest agent restarts in a loop (no
injected configuration), and the network stack (ifupdown and isc-dhcp-client
come with the upstream `guest-agent` element) has not been checked against
the strict IPv6 contract. Known upstream behaviour on 2026.x non-dev images:
`trove-image-loader.service` fails at boot (it reads
`/etc/trove/controller.conf`, which only exists in devstack); it is
harmless, the guest agent pulls its images itself.

Planned check, closer to what Trove does: boot it with a key pair and
config drive files mimicking Trove's injection, SSH in as `ubuntu`, then
assert `sudo -n true`, a locked password (`passwd -S ubuntu`), password
authentication refused, `docker info` working with the pinned version,
`guest-agent.service` started and logging its connection attempt to the
message queue. A full check needs a Trove control plane (devstack with the
image registered).

## Repository layout

```
VERSION                     OpenStack series, e.g. 2026.2
build/
  dib-build.sh              DIB build hook (out dir as $1, version as $2), pins
  detect-upstream.sh        newest Trove stable/YYYY.N branch
elements/oic-trove-guest/   local DIB element: Docker pin, key-only SSH
.github/workflows/
  release.yml               tag push: calls build-dib-image.yml
  watch.yml                 daily: calls upstream-watch.yml
  sync-latest.yml           manual: point latest/ to a published version
.gitignore                  repo-local override for the global build/ exclusion
LICENSE                     GPL-2.0
```

## License

The build tooling in this repository is [GPL-2.0](LICENSE). The image content
keeps its own licenses (Trove and diskimage-builder are Apache-2.0, Docker CE
is Apache-2.0, Ubuntu packages under their respective licenses). OpenStack is
a trademark of the Open Infrastructure Foundation. This project is not
affiliated with it.

[dib]: https://docs.openstack.org/diskimage-builder/
[octavia]: https://github.com/open-img-cloud/octavia-amphora
[manila]: https://github.com/open-img-cloud/manila-service-image
[tarballs]: https://tarballs.opendev.org/openstack/trove/images/
[build]: https://docs.openstack.org/trove/latest/admin/building_guest_images.html
[prod]: https://docs.openstack.org/trove/latest/admin/run_trove_in_production.html
