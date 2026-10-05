# bluefin-ipa

Bluefin and bluefin-dx with `freeipa-client` baked into the image instead of
layered per-host.

Produces two images across two channels — four builds — rebuilt daily against
upstream:

| image | base |
| --- | --- |
| `ghcr.io/aatchison/bluefin-ipa` | `ghcr.io/ublue-os/bluefin` |
| `ghcr.io/aatchison/bluefin-dx-ipa` | `ghcr.io/ublue-os/bluefin-dx` |

Each is built for **both channels**, mirroring upstream: `:latest` and `:stable`,
plus channel-qualified date tags `:latest-YYYYMMDD` and `:stable-YYYYMMDD`.

Match the channel the host is already on — `rpm-ostree status` shows it. Moving a
host between channels is a behaviour change on its own, separate from anything this
repo is trying to fix, so don't do it by accident. work-dev-2 tracks `:stable`;
claudia3 and judah track `:latest`.

Baked in: `freeipa-client`, `sssd-ipa`, `oddjob-mkhomedir`, `mosh`, `ghostty`.
That set is not arbitrary — it is every package currently layered on any host in
the fleet. A package that a host layers but the image lacks turns a switch into a
silent regression, which is the exact failure this repo exists to prevent.

## Why

The IPA provider has been lost on these hosts three separate ways, all of which
share one cause: `freeipa-client` lived in local mutable state (`rpm-ostree`
layering), which is orthogonal to the image.

- a transient `usroverlay` discarded the layer at reboot (work-dev-2)
- a staged-but-unrebooted install never activated (work-dev-2)
- a `bluefin` → `bluefin-dx` rebase dropped the layer entirely (clement)

Baking the packages in makes them part of the thing that gets atomically
swapped. `bootc status` becomes the single source of truth, and
`InterruptedLiveCommit` stops being a reachable failure mode.

## What is and isn't in the image

**In:** `freeipa-client`, `sssd-ipa`, `oddjob-mkhomedir` — the client software —
plus `mosh` and `ghostty`, which hosts were layering. `ghostty` is not in Fedora;
it comes from the `scottames` COPR, which the build enables for the install and
then disables again so hosts do not boot with a third-party repo live.

**Out:** everything host-specific. `/etc/ipa`, the host keytab, `sssd.conf`,
`~/.k5login` collision workarounds. bootc preserves `/etc` across upgrades and
`ipa-client-install` is what should write it. No secret belongs in a registry
image.

**Also in, and easy to miss:** `/usr/lib/tmpfiles.d/bluefin-ipa-var.conf`. On an
ostree/bootc system `/var` is host state, not image content — anything the build
writes there is discarded, and a deployed host starts with a `/var` populated only
by `systemd-tmpfiles`. So a baked-in RPM can be fully installed and still be
missing every directory it declares under `/var`. fulton hit this on 2026-08-10:
`rpm -q freeipa-client` green, and `ipa-client-install` failing one `mkdir` at a
time on `/var/lib/ipa-client/sysrestore`, then `/var/lib/ipa-client/pki`.
`freeipa-client` ships no `tmpfiles.d` rules of its own, so that file supplies
them, for `certmonger` too.

`build_files/build.sh` asserts `/usr/lib64/sssd/libsss_ipa.so` exists before the
build succeeds — the absence of that file is the exact tell for "sssd.conf says
`id_provider = ipa` but there is no IPA code on disk".

## Setup

### 1. Signing key

CI signs every pushed image. Generate a keypair (`cosign.key` is gitignored):

```bash
COSIGN_PASSWORD="" cosign generate-key-pair
```

cosign is not installed here. Either grab the release binary:

```bash
curl -sSLo /tmp/cosign https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
chmod +x /tmp/cosign && /tmp/cosign generate-key-pair
```

or run it in a container. Then:

```bash
gh secret set SIGNING_SECRET < cosign.key
git add cosign.pub && git commit -m "add signing public key"
```

Keep `cosign.key` somewhere durable and out of the repo.

### 2. First build

```bash
gh workflow run build.yml
gh run watch
```

Both packages default to private on first push. Make them public so hosts can
pull without registry auth — private images work, but every host then needs
credentials available to the update timer, which is a standing failure mode of
its own. The images contain no secrets.

Package settings → Change visibility → Public, for each of
`bluefin-ipa` and `bluefin-dx-ipa`.

### 3. Switch a host

Two prerequisites first. Skipping either fails loudly or, worse, silently
downgrades the host's security posture.

**a. Let the host find the signature.** ublue ships this for its own namespace,
which is why upstream images verify out of the box. Ours needs the equivalent, or
`bootc switch` dies with *"A signature was required, but no signature exists"*:

```bash
sudo tee /etc/containers/registries.d/aatchison.yaml <<'EOF'
docker:
  ghcr.io/aatchison:
    use-sigstore-attachments: true
EOF
```

**b. Install the public key and trust it.** `matchRepository`, not `matchExact` —
`:latest` and `:stable-YYYYMMDD` are different tags on one repo, and a pinned
rollback has to verify too. Back up `policy.json` first: a malformed policy blocks
every image pull, including the rollback path.

```bash
sudo mkdir -p /etc/pki/containers
sudo curl -sSfL https://raw.githubusercontent.com/aatchison/bluefin-ipa/main/cosign.pub \
     -o /etc/pki/containers/aatchison.pub
sudo cp /etc/containers/policy.json /etc/containers/policy.json.orig
# then add to .transports.docker in policy.json:
#   "ghcr.io/aatchison": [{"type": "sigstoreSigned",
#                          "keyPath": "/etc/pki/containers/aatchison.pub",
#                          "signedIdentity": {"type": "matchRepository"}}]
```

**Then switch**, matching the channel the host already tracks:

```bash
sudo bootc switch --enforce-container-sigpolicy ghcr.io/aatchison/bluefin-dx-ipa:latest
sudo systemctl reboot
```

`--enforce-container-sigpolicy` is not optional. Without it the pull is still
checked, but the deployment origin records as `ostree-unverified-registry:` and
later uupd pulls stop requiring a signature. With it, `rpm-ostree status` reads
`ostree-image-signed:` — check for that string, it is the proof.

Then verify — do not trust `systemctl is-active sssd` alone:

```bash
rpm-ostree status                         # booted entry: ostree-image-signed, and
                                          # NO LayeredPackages line at all
ls /usr/lib64/sssd/libsss_ipa.so          # must exist
getent passwd arron                       # must resolve via IPA
rpm -q ghostty mosh                       # present, from the image
```

The absence of a `LayeredPackages` line on the booted deployment is the whole
point. Note the *rollback* deployment will still show its old layers — read
carefully which entry you are looking at.

If the host had `freeipa-client` layered, remove the layer after the switch so
the image is the only source: `sudo rpm-ostree uninstall freeipa-client`.

### 4. Updates

Nothing further. Bluefin ships **uupd** and enables `uupd.timer`, which pulls the
OS image, flatpaks and distrobox containers in one coordinated pass. It will
follow `:latest` on your image the same way it followed upstream's.

The other update timers are left off, but *disabled*, not masked — Bluefin's
build explicitly disables `rpm-ostreed-automatic.timer`, and
`bootc-fetch-apply-updates.timer` ships disabled by bootc's own preset and is
never touched. (Bluefin **LTS** does mask them; this repo does not build on LTS.)
So `systemctl unmask` is a no-op here and proves nothing. To confirm what is
actually driving updates:

```bash
systemctl is-enabled uupd.timer bootc-fetch-apply-updates.timer rpm-ostreed-automatic.timer
```

## Rolling back

When an upstream regression lands, pin one host to a known-good day rather than
bisecting blind:

```bash
sudo bootc switch ghcr.io/aatchison/bluefin-dx-ipa:latest-20260731
```

`sudo bootc rollback` still returns to the previous deployment as usual.

## A note on signature verification

Earlier revisions of this file treated on-host verification as optional. It is
not, and calling it optional was wrong: a Bluefin host arrives running
`ostree-image-signed` against ublue's keys, so switching it to an unverified ref
is a **downgrade**, not a neutral default. Steps 3a/3b above exist to keep the
host exactly as verified as it was.

The failure mode to know: without the `registries.d` entry the signature is never
looked up, and without `--enforce-container-sigpolicy` the origin silently records
as unverified even though the first pull was checked. Both are quiet in different
ways — one fails the switch outright, the other succeeds and leaves you worse off.
`rpm-ostree status` showing `ostree-image-signed:` is the only reliable proof.
