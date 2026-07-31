# bluefin-ipa

Bluefin and bluefin-dx with `freeipa-client` baked into the image instead of
layered per-host.

Produces two images, rebuilt daily against upstream `:latest`:

| image | base |
| --- | --- |
| `ghcr.io/aatchison/bluefin-ipa` | `ghcr.io/ublue-os/bluefin` |
| `ghcr.io/aatchison/bluefin-dx-ipa` | `ghcr.io/ublue-os/bluefin-dx` |

Each is tagged `:latest` and `:YYYYMMDD`.

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

**In:** `freeipa-client`, `sssd-ipa`, `oddjob-mkhomedir` — the client software.

**Out:** everything host-specific. `/etc/ipa`, the host keytab, `sssd.conf`,
`~/.k5login` collision workarounds. bootc preserves `/etc` across upgrades and
`ipa-client-install` is what should write it. No secret belongs in a registry
image.

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

Once per host:

```bash
sudo bootc switch ghcr.io/aatchison/bluefin-dx-ipa:latest
sudo systemctl reboot
```

Then verify — do not trust `systemctl is-active sssd` alone:

```bash
bootc status                              # confirm the booted image
ls /usr/lib64/sssd/libsss_ipa.so          # must exist
getent passwd arron                       # must resolve via IPA
```

If the host had `freeipa-client` layered, remove the layer after the switch so
the image is the only source: `sudo rpm-ostree uninstall freeipa-client`.

### 4. Updates

Nothing further. Bluefin ships **uupd**, which masks
`bootc-fetch-apply-updates.timer` deliberately and supersedes it — `uupd.timer`
pulls the OS image, flatpaks and distrobox containers in one coordinated pass.
It will follow `:latest` on your image the same way it followed upstream's.

## Rolling back

When an upstream regression lands, pin one host to a known-good day rather than
bisecting blind:

```bash
sudo bootc switch ghcr.io/aatchison/bluefin-dx-ipa:20260731
```

`sudo bootc rollback` still returns to the previous deployment as usual.

## Optional: enforce signature verification on-host

CI signs images, but the hosts do not verify by default. Enforcement is a
separate step and is deliberately not baked in — a wrong policy blocks all
future updates. To enable it, install `cosign.pub` on the host and add a
matching `transports` entry to `/etc/containers/policy.json`, mirroring the
`sigstore` block upstream Bluefin already uses for `ghcr.io/ublue-os`. Test on
one host and confirm an update still applies before rolling it out.
