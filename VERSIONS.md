# VERSIONS.md

### v1.2.1

 - perform installation of Tailscale different between Proxmox versions
 - attempt initial ping reachability tests a few times
 - make `curl` a dependency
 - remove `run_tailscale_cert_services` function (no longer needed)

---

### v1.2.0

This version changes a core piece of architecture for tailmox - mainly that `tailscale serve` is now used as a reverse proxy for the pveproxy service, rather than managing the Tailscale certificate manually. This allows communication between hosts on port 443, meaning that URLs can now exclude the ":8006" port specification at the end. It also decouples Proxmox from Tailscale a bit, insomuch that binding the Tailscale certificate directly to pveproxy is no longer necessary.

Because of this change, [tailscale-cert-services](https://github.com/willjasen/tailscale-cert-services) is no longer needed.

- switch to using `tailscale serve` to handle HTTP/API communication
- check that TCP 443 is available on all tailmox hosts (available via `tailscale serve`)
- ensure that the ping check tries a few times over a few seconds
- clean up unneccessary console output/logging

---

### v1.1.0

 - test compatibility with Proxmox v9
 - add a staging mode that installs Tailscale and retrieves the certificate, then stops
 - fixes three separate things in issue [#4](https://github.com/willjasen/tailmox/issues/4)
