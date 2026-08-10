#!/usr/bin/bash
set -euxo pipefail

# Image family: "bluefin", "bluefin-dx" or "ucore-hci". Only used to gate
# desktop-only packages -- everything IPA-related is common to all of them.
VARIANT="${1:-bluefin}"

# Software only. Enrollment state (/etc/ipa, the host keytab, sssd.conf) stays
# per-host -- bootc preserves /etc across upgrades, and ipa-client-install is
# what should write it. Baking packages here is the whole point: a layered
# package can vanish on a rebase, an image layer cannot.
#
# For ucore this is not merely tidier, it is the ONLY way that works. ucore's
# base ships unbound-libs, which creates the 'unbound' user and group at boot
# via systemd-sysusers -- into /etc/group only. Layering the full unbound
# package (a hard dependency of freeipa-client-encrypted-dns) then fails with
#   error: While applying overrides for pkg unbound:
#          Could not find group 'unbound' in group file
# because rpm-ostree resolves ownership against the base image's
# /usr/lib/group, where the entry does not exist. Verified on fulton
# 2026-08-10: plain `rpm-ostree install unbound` reproduces it on its own.
#
# Installing it HERE works because dnf5 runs the sysusers scriptlet normally
# during the build, so the account exists before any file is chowned to it.
# Note the account lands in the image's /etc/group, which `ostree container
# commit` relocates to /usr/etc/group -- NOT /usr/lib/group, which belongs to
# the upstream base and a derived build cannot write. The distinction matters:
# baking unbound in fixes THIS package, but layering some other package that
# owns unbound-group files on a running host would still hit the same error.

dnf5 -y install \
    freeipa-client \
    sssd-ipa \
    oddjob-mkhomedir \
    autofs

# sssd-ipa is listed explicitly rather than relied on as a freeipa-client
# dependency. It ships /usr/lib64/sssd/libsss_ipa.so, whose absence is the
# exact tell for "sssd.conf says id_provider = ipa but no IPA code on disk".
test -f /usr/lib64/sssd/libsss_ipa.so

# autofs is explicit for the same reason. It happens to be in the bluefin base
# already, but it is NOT in ucore's -- and it is what mounts the IPA automount
# maps under /var/nfshome. Without it a host enrolls cleanly and then silently
# has no home directory.
rpm -q autofs

# Extras that were previously layered per-host. Each one here is a package that
# a bootc switch would otherwise silently drop -- the same way the bluefin ->
# bluefin-dx rebase dropped ghostty off clement.
dnf5 -y install mosh

# Allowlist, not a catch-all. An unrecognised VARIANT is a build error rather
# than "quietly get the desktop branch" -- otherwise a typo, or a new headless
# row added to the matrix under a name that does not start with "ucore", ends
# up enabling a third-party COPR and installing a GUI terminal on a server,
# and nothing downstream notices.
case "$VARIANT" in
  bluefin|bluefin-dx)
    # ghostty is NOT in the Fedora repos -- it comes from the scottames COPR,
    # which is how judah had it layered. Enable the COPR only for this install,
    # then disable it again: a host booting this image should not carry a
    # third-party repo enabled at runtime, where it could silently shadow base
    # packages later.
    dnf5 -y install dnf5-plugins
    dnf5 -y copr enable scottames/ghostty
    dnf5 -y install ghostty
    dnf5 -y copr disable scottames/ghostty
    rpm -q ghostty
    ;;
  ucore-hci)
    # Headless server: no GUI terminal. The rest of ucore-hci's stack --
    # libvirt-client/qemu-kvm/virt-install/cockpit-machines/zfs/podman -- is
    # already in its base, so nothing virt-related needs adding here.
    # Assert the negative too, so the allowlist above cannot rot silently.
    # Written as an if, not `! rpm -q ghostty`: `set -e` explicitly does NOT
    # trigger on a command whose return value is inverted with `!`, so that
    # form would have been an assertion that can never fail.
    if rpm -q ghostty >/dev/null 2>&1; then
        echo "build.sh: ghostty present on a headless variant" >&2
        exit 1
    fi
    ;;
  *)
    echo "build.sh: unknown VARIANT '$VARIANT'" >&2
    exit 1
    ;;
esac

# Installing a unit does NOT enable it: Fedora's default preset is `disable *`,
# and neither autofs nor oddjobd ships a preset entry. Without this the image
# contains everything needed for IPA home directories and mounts none of them --
# an enrolled host with autofs installed, autofs.service dead, and no mkhomedir
# fallback because oddjobd is off too. `rpm -q autofs` passes throughout, which
# is exactly why that assertion alone was not enough.
systemctl enable autofs.service oddjobd.service
systemctl is-enabled autofs.service oddjobd.service

# Prove the packages that make a switch non-regressive are actually here,
# rather than trusting the install exited 0.
rpm -q mosh freeipa-client oddjob-mkhomedir

# unbound is the entire reason this image exists for ucore, so assert it
# directly -- both the package and the account whose absence breaks layering.
# Everything above this line is satisfiable by packages the base already
# guarantees, so without these two checks a regression in the thing the build
# is FOR would still publish green.
rpm -q unbound
getent group unbound

dnf5 clean all
