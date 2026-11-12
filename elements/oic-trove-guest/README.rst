oic-trove-guest
===============

openimages.cloud additions to the upstream Trove guest image elements
(``guest-agent``, ``ubuntu-docker``, ``ubuntu-guest`` from
``openstack/trove`` ``integration/scripts/files/elements``).

* ``install.d/20-oic-docker-pin`` runs just before ``ubuntu-docker``'s
  ``21-docker`` and pins Docker CE and containerd.io to exact versions through
  apt preferences.
* ``post-install.d/90-oic-key-only`` checks that the pinned versions were
  installed and the Docker repository key is the expected one, removes the
  build-time pin, and makes SSH key-only: upstream's ``ubuntu-guest`` element
  creates the guest user with a password equal to its name; here that
  password and root's are replaced by a locked hash, and password
  authentication is disabled in sshd and cloud-init.

Environment variables (set by ``build/dib-build.sh``):

``DIB_OIC_DOCKER_VERSION``
    Exact apt version of ``docker-ce``, ``docker-ce-cli`` and
    ``docker-ce-rootless-extras``.

``DIB_OIC_CONTAINERD_VERSION``
    Exact apt version of ``containerd.io``.

``GUEST_USERNAME``
    Guest user (default ``ubuntu``), shared with the upstream elements.
