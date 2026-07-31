#!/usr/bin/bash
set -euxo pipefail

# Software only. Enrollment state (/etc/ipa, the host keytab, sssd.conf) stays
# per-host -- bootc preserves /etc across upgrades, and ipa-client-install is
# what should write it. Baking packages here is the whole point: a layered
# package can vanish on a rebase, an image layer cannot.

dnf5 -y install \
    freeipa-client \
    sssd-ipa \
    oddjob-mkhomedir

# sssd-ipa is listed explicitly rather than relied on as a freeipa-client
# dependency. It ships /usr/lib64/sssd/libsss_ipa.so, whose absence is the
# exact tell for "sssd.conf says id_provider = ipa but no IPA code on disk".
test -f /usr/lib64/sssd/libsss_ipa.so

# Extras that were previously layered per-host. Each one here is a package that
# a bootc switch would otherwise silently drop -- the same way the bluefin ->
# bluefin-dx rebase dropped ghostty off clement.
dnf5 -y install mosh

# ghostty is NOT in the Fedora repos -- it comes from the scottames COPR, which
# is how judah had it layered. Enable the COPR only for this install, then
# disable it again: a host booting this image should not carry a third-party
# repo enabled at runtime, where it could silently shadow base packages later.
dnf5 -y install dnf5-plugins
dnf5 -y copr enable scottames/ghostty
dnf5 -y install ghostty
dnf5 -y copr disable scottames/ghostty

# Prove the two packages that make a switch non-regressive for judah/clement are
# actually here, rather than trusting the install exited 0.
rpm -q ghostty mosh

dnf5 clean all
