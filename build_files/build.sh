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
# In this container build dnf5 runs sysusers normally and the commit below
# folds the group into /usr/lib/group, so the problem never arises.

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

case "$VARIANT" in
  ucore*)
    # Headless server: no GUI terminal. The rest of ucore-hci's stack --
    # libvirt-client/qemu-kvm/virt-install/cockpit-machines/zfs/podman -- is
    # already in its base, so nothing virt-related needs adding here.
    :
    ;;
  *)
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
esac

# Prove the packages that make a switch non-regressive are actually here,
# rather than trusting the install exited 0.
rpm -q mosh freeipa-client oddjob-mkhomedir

dnf5 clean all
