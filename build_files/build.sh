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

# Extras that were previously layered per-host. Left commented until confirmed
# available in the enabled repos for the base you build against -- a missing
# package here fails the build for every host at once.
# dnf5 -y install ghostty

dnf5 clean all
