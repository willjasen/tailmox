# Tailmox Test Image Build Notes

This document is the handoff checklist for building a replacement Tailmox
Proxmox test image. It records the differences found after deploying the
current image and defines a small compatibility scheme for future images and
clone-preparation helpers.

## Current image: legacy release 0

The image currently referenced by `template.json` predates explicit image
versioning. Treat it as:

```text
TAILMOX_IMAGE_RELEASE=0
TAILMOX_PREPARE_API=0
```

Identifying values:

- Compressed CIDv1: `bafybeig3k2tpv33pcoveatirpbio4qgr7kltpnbau3ftlgpgi7emombzqy`
- Compressed SHA-256: `5644986a684318f2a7e85bc413f810f41aa5d2a2454cb7a3bf5cf3da98a97e32`
- Uncompressed SHA-256: `2b4b219ca7974ef4921e0b9fc0f213b07e1b4e37400b5ca3ed9dee93588e30bb`
- Initial hostname: `tailmox-image`
- Initial network: static `192.168.123.90/24` on guest bridge `vmbr0`
- Initial Tailmox checkout: `main` at `e8cf73d827b8ae45d5a098541d6545e35b331ea7`

The legacy image does not contain a DHCP client. Its clones therefore need a
temporary route to install one before they can adopt the preferred DHCP
configuration. `prepare-linked-clone.sh` supports this legacy layout, but the
next image should eliminate that bootstrap step.

## Changes to bake into the next image

### Required

- Install `isc-dhcp-client` and retain it in the image.
- Configure `ens18` as a port of guest bridge `vmbr0` and configure `vmbr0`
  with DHCP. Do not ship a static IPv4 address or gateway.
- Keep the guest bridge named `vmbr0`. `vlan3` is the bridge on the outer
  Proxmox host and must not be written into the nested guest configuration.
- Use a neutral hostname such as `tailmox-image` and map it through
  `127.0.1.1`, not through a deployment-specific address.
- Include and enable `qemu-guest-agent` so a clone can be prepared before SSH
  networking is available.
- Include and enable `serial-getty@ttyS0.service`; the Proxmox clone
  configuration provides `serial0: socket` and `vga: serial0`, but the guest
  must run the getty before `qm terminal <VMID>` can provide a login shell.
- Place a clean Tailmox checkout at `/opt/tailmox`. Do not include uncommitted
  files, credentials, test output, or host-specific configuration.
- Ensure `/usr/local/bin/tailmox` resolves to `/opt/tailmox/tailmox`.
- Do not authenticate Tailscale, configure Tailscale Serve, or create/join a
  Proxmox cluster in the image.
- Do not bake `dev-tailmox` into a generally reusable image. The preparation
  helper should set the service label for the deployment being created.
- Set a per-clone root password during preparation. Generated passwords are
  reported once to the operator but must not be written to the image,
  repository, logs, or Proxmox notes.

### Clone identity and cleanup

Before publishing, verify that the image does not carry identity or state that
must be unique per clone:

- Tailscale node identity, auth keys, or state
- Proxmox cluster membership or Corosync configuration
- DHCP leases
- shell history, temporary files, logs containing environment details, or
  package-manager credentials
- a machine ID or SSH host keys that would be duplicated by linked clones

Regenerate identity at first boot where the operating system requires it. Do
not remove Proxmox-managed state unless the image-build procedure has been
tested to prove that the nested Proxmox installation still boots correctly.

## Versioning and compatibility contract

Use two independent positive integers:

- `TAILMOX_IMAGE_RELEASE` identifies an immutable image build. Increment it
  for every published image, even if its preparation interface is unchanged.
- `TAILMOX_PREPARE_API` identifies the assumptions shared by the image and
  `prepare-linked-clone.sh`. Increment it only when the helper needs materially
  different detection or migration behavior.

The next image should start with release `1` and preparation API `1`.

Bake this root-owned file into every versioned image:

```text
# /etc/tailmox-image-release
TAILMOX_IMAGE_RELEASE=1
TAILMOX_PREPARE_API=1
```

The file must contain only literal integer assignments, be owned by root, and
not be writable by non-root users. A missing file means legacy release/API `0`.

Each preparation helper should declare the API range it supports. Before
changing the guest, it should:

1. Read and strictly validate `/etc/tailmox-image-release`.
2. Treat a missing file as API `0` only while legacy support is intentional.
3. Refuse an API newer than the helper supports.
4. Select preparation steps by API instead of guessing from image filenames.
5. Print the detected image release, preparation API, and deployed Git commit
   in its completion summary.

Keep published images immutable. Never replace the bytes behind an existing
release entry; add a new release with new hashes and CIDs.

## Future manifest shape

When release 1 is published, migrate `template.json` from one implicit image
to explicit releases. Preserve enough metadata to verify both compressed and
uncompressed artifacts. A suggested structure is:

```json
{
  "schema_version": 1,
  "current_release": 1,
  "releases": {
    "1": {
      "prepare_api": 1,
      "created": "YYYY-MM-DD",
      "proxmox_version": "9.x",
      "artifacts": {
        "compressed": {
          "name": "tailmox-1.qcow2.tar.xz",
          "size_in_bytes": 0,
          "sha256": "replace-at-publish-time",
          "cid_v1": "replace-at-publish-time"
        },
        "uncompressed": {
          "name": "tailmox-1.qcow2",
          "size_in_bytes": 0,
          "sha256": "replace-at-publish-time",
          "cid_v1": "replace-at-publish-time"
        }
      }
    }
  }
}
```

Update the download and template-creation helpers in the same commit that
changes the manifest. They should default to `current_release` and optionally
accept an exact release, allowing an older immutable image to be redeployed.

## Release procedure

1. Build the image from a documented Proxmox version and apply the required
   configuration above.
2. Shut it down cleanly and verify that no secrets or clone-specific identity
   remain.
3. Boot a linked clone, run the matching preparation helper, and verify:
   hostname, dynamic DHCP address, default route, DNS, clean Git checkout,
   command link, service label, QEMU guest agent, and absence of Tailscale or
   cluster enrollment.
4. Reboot the clone and repeat the network and identity checks.
5. Run `./tailmox test` from the deployed checkout.
6. Shut down the source image before exporting it.
7. Calculate sizes and SHA-256 hashes for both artifacts.
8. Add the artifacts to IPFS, verify retrieval through the local Kubo gateway
   and at least one independent gateway, and record the CIDv1 values.
9. Add a new immutable release entry to `template.json`; do not edit the
   hashes or CIDs of older releases.
10. Create the outer Proxmox template and ensure each linked clone receives a
    snapshot and useful Markdown note before its first boot.

## Observed deployment used to create this checklist

The three release-0 clones required these post-image changes:

- unique hostnames derived from the VM IDs when deploying additional
  isolated test environments (for example `tailmox-tabcd` for VM `50011`)
- DHCP on guest `vmbr0`, with their outer NICs attached to `vlan3`
- installation of `isc-dhcp-client`
- correction of the image's static hostname entry in `/etc/hosts`
- a clean `/opt/tailmox` checkout on `dev`
- initialization of `/usr/local/bin/tailmox`
- deployment-specific service label `dev-tailmox`

These are preparation responsibilities unless explicitly listed above as
items that should be baked into the next generic image.
