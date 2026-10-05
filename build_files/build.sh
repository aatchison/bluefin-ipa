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
#
# Xvfb backs `orca serve` (the Orca IDE's headless runtime) on claudia3: its
# Electron process segfaults with no display server at all, and the serve
# wrapper looks for Xvfb by name in PATH. Common to all variants because any
# host may be asked to act as a headless Orca server.
dnf5 -y install mosh xorg-x11-server-Xvfb

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

    # virt-manager ships in the bluefin-dx base and is absent from plain
    # bluefin. judah is on plain bluefin and connects only to REMOTE libvirt
    # hosts, so install the client half and stop there.
    #
    # install_weak_deps=False is load-bearing, not tidying. virt-manager
    # Recommends libvirt-daemon-kvm, so a plain `dnf5 install virt-manager`
    # resolves to 156 packages / 272 MiB and turns a laptop into a local
    # hypervisor -- qemu-system-x86-core, libvirt-daemon, swtpm, virtiofsd,
    # xen-libs -- none of which a remote-only client ever runs. With weak deps
    # off it is 20 packages / 50 MiB: the GUI, libvirt-libs/python3-libvirt and
    # the console widgets (gtk-vnc2, spice-gtk3). openssh-clients and
    # openssh-askpass are already in the base, which matters more than it looks:
    # virt-manager sets SSH_ASKPASS_REQUIRE=force, so with no askpass binary a
    # qemu+ssh:// connection fails to prompt and gives no visible reason.
    #
    # This replaces a `brew install virt-manager` on judah, which launched and
    # then died at
    #   GLib-GIO-ERROR: Settings schema 'org.virt-manager.virt-manager' is not installed
    # because brew keeps its schemas in ~/.linuxbrew/share/glib-2.0/schemas and
    # nothing puts that directory on XDG_DATA_DIRS. The same gap hid the app from
    # GNOME's menu, so its launcher fell through to a Bazaar "install this" stub.
    # An RPM has neither problem: schemas land in /usr/share and the desktop
    # entry is where the shell already looks.
    if [ "$VARIANT" = "bluefin" ]; then
        dnf5 -y --setopt=install_weak_deps=False install virt-manager libvirt-client
        rpm -q libvirt-client

        # Assert the negative: if a rebase or a dependency change starts pulling
        # the daemon back in, the weak-deps decision above has silently reverted
        # and this image has regrown a hypervisor nobody asked for. Written as an
        # if, not `! rpm -q`, for the same reason as the ucore check below --
        # `set -e` does not trigger on an inverted return value.
        if rpm -q libvirt-daemon-kvm >/dev/null 2>&1; then
            echo "build.sh: libvirt-daemon-kvm pulled into a remote-only client" >&2
            exit 1
        fi
    fi

    # Checked for BOTH desktop variants, not just the branch that installs.
    # bluefin-dx inherits virt-manager from its base, and an upstream drop there
    # is exactly the silent regression this file exists to catch -- the same
    # shape as the bluefin -> bluefin-dx rebase that took ghostty off clement.
    rpm -q virt-manager

    # The package installing is not the property that matters; these three files
    # are. A GSettings schema that ships uncompiled fails at runtime in precisely
    # the way brew's did, and a missing desktop entry is what sent the launcher
    # to Bazaar. Both are invisible to `rpm -q`.
    test -f /usr/share/glib-2.0/schemas/org.virt-manager.virt-manager.gschema.xml
    test -f /usr/share/glib-2.0/schemas/gschemas.compiled
    test -f /usr/share/applications/virt-manager.desktop
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

# /var is host state on an ostree/bootc system, NOT image content: anything a
# build leaves under /var is discarded, and a deployed host boots with a /var
# populated only by systemd-tmpfiles. So the directories freeipa-client and
# certmonger declare in their RPMs simply do not exist on a fresh host, even
# though the packages above are unquestionably installed. fulton hit this on
# 2026-08-10 -- `rpm -q freeipa-client` green, and ipa-client-install failing
# one mkdir at a time on /var/lib/ipa-client/sysrestore, then .../pki. The
# config goes in /usr/lib/tmpfiles.d (image) and not /etc/tmpfiles.d, which is
# host config a host is entitled to edit or a rebase to leave behind.
install -D -m 0644 -o root -g root \
    /ctx/bluefin-ipa-var.conf /usr/lib/tmpfiles.d/bluefin-ipa-var.conf

# Parse it here, at build time, because a bad tmpfiles line does not fail --
# it is logged once by systemd-tmpfiles-setup at boot and skipped, leaving the
# host in exactly the state this file exists to prevent, with a green build and
# a green `test -f`. --dry-run is what makes this safe to run in the build:
# it resolves and validates every line without creating anything, which matters
# because directories created here under /var would be thrown away regardless.
systemd-tmpfiles --dry-run --create /usr/lib/tmpfiles.d/bluefin-ipa-var.conf

# Parsing clean is not the same as saying anything. An empty -- or truncated --
# file also parses clean, so assert each directory is actually declared.
for d in /var/lib/ipa-client /var/lib/ipa-client/sysrestore \
         /var/lib/ipa-client/pki /var/lib/ipa /var/lib/certmonger \
         /var/lib/certmonger/cas /var/lib/certmonger/local \
         /var/lib/certmonger/requests; do
    grep -Eq "^d[[:space:]]+${d}[[:space:]]" \
        /usr/lib/tmpfiles.d/bluefin-ipa-var.conf || {
        echo "build.sh: tmpfiles config does not declare ${d}" >&2
        exit 1
    }
done

# Prove the packages that make a switch non-regressive are actually here,
# rather than trusting the install exited 0.
rpm -q mosh freeipa-client oddjob-mkhomedir
test -x /usr/bin/Xvfb

# unbound is the entire reason this image exists for ucore, so assert it
# directly -- both the package and the account whose absence breaks layering.
# Everything above this line is satisfiable by packages the base already
# guarantees, so without these two checks a regression in the thing the build
# is FOR would still publish green.
rpm -q unbound
getent group unbound

dnf5 clean all
