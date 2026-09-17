# TO-DO.md

ensure that "resolvconf" is or gets installed along with the other packages. Tailscale needs this to manage Tailscale DNS on the Proxmox host to ensure that Tailscale DNS is being used.

---

getting `curl: (22) The requested URL returned error: 403` at the end of `tailscale stage`, but a dig lookup gives:

```
root@tailmox1:/opt/tailmox# dig tailmox1.risk-mermaid.ts.net

; <<>> DiG 9.20.15-1~deb13u1-Debian <<>> tailmox1.risk-mermaid.ts.net
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 20880
;; flags: qr aa rd ra ad; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 0

;; QUESTION SECTION:
;tailmox1.risk-mermaid.ts.net.	IN	A

;; ANSWER SECTION:
tailmox1.risk-mermaid.ts.net. 5	IN	A	100.95.182.117

;; Query time: 1 msec
;; SERVER: 100.100.100.100#53(100.100.100.100) (UDP)
;; WHEN: Thu Sep 17 17:24:08 EDT 2026
;; MSG SIZE  rcvd: 90
```

---
