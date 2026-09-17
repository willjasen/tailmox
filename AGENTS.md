# AGENTS.md

## Project overview

Tailmox clusters Proxmox VE 8 and 9 hosts over Tailscale. The project is
primarily Bash and can modify networking, systemd services, Tailscale
configuration, and Proxmox cluster state.

Treat changes to installation, networking, authentication, clustering, storage,
and VM-management code as high risk.

## Repository layout

- `tailmox` — user-facing command dispatcher and test runner.
- `tailmox.sh` — main installer, web-terminal launcher, and clustering workflow.
- `tailmox-web.service` — systemd unit for the browser terminal.
- `tests/` — local shell tests using temporary directories and command mocks.
- `test-env/` — tooling for building and controlling nested Proxmox test VMs.
- `README.md` — current installation, usage, architecture, and ACL guidance.
- `GUIDE.md` — original/manual clustering guide.
- `VERSIONS.md` — release history.

## Working conventions

- Preserve compatibility with Bash and the existing script style.
- Quote variable expansions unless intentional word splitting is required.
- Prefer `[[ ... ]]` for Bash conditionals.
- Use `local` variables inside functions.
- Use `printf` for new output instead of relying on implementation-specific
  `echo` behavior.
- Return nonzero on failure and fail closed when host, peer, or network state is
  incomplete.
- Keep normal development runnable without root where practical.
- Make privileged paths configurable through `TAILMOX_*` environment variables
  so tests can redirect them into temporary directories.
- Tailmox is installed at `/opt/tailmox` on Proxmox hosts.
- When remoting into a Proxmox host in the Tailmox cluster, use the local SSH
  key and log in as `root`.
- Never print, log, or commit Tailscale auth keys, Proxmox API tokens,
  passwords, or other credentials.
- Do not silently overwrite unrelated files, commands, services, or existing
  configuration.

## Safety requirements

Do not run the real clustering, staging, serving, VM deployment, template
creation, or VM-reversion workflows unless the user explicitly requests it and
confirms the intended Proxmox test environment.

In particular, treat these as potentially destructive or state-changing:

- `pvecm create`, `pvecm add`, and other cluster operations.
- Package installation and Tailscale authentication.
- Changes under `/etc`, `/var`, or `/usr/local/bin`.
- `systemctl` operations.
- `tailscale serve` configuration.
- Proxmox API calls.
- VM cloning, starting, stopping, snapshotting, or reverting.
- Storage-image downloads and template creation.

## Public web security

- Keep the Internet-facing monitor isolated in `tailmox-public-monitor.py`; do
  not add privileged handlers, command execution, configuration reads, or
  private monitor proxying to that service.
- Treat `tailmox-monitor.py` and its port `8088` as private even when a route is
  read-only. Never expose it through an Internet-facing proxy.
- Extend the public snapshot through explicit exporter and origin allowlists.
  Reject unknown fields at the origin, and never export IP addresses, node IDs,
  cluster names, logs, credentials, or raw command output.
- Keep public request concurrency, request duration, file size, collection
  sizes, strings, and numeric values bounded. Public snapshot files must be
  regular, fresh, non-symlink files in a root-owned runtime directory.
- Preserve the restrictive CSP and other browser headers. Any new third-party
  script or network destination requires an explicit, narrowly scoped policy
  change and matching tests.
- Keep `tests/test-public-monitor.sh` mandatory in `tailmox test`. It must verify
  both runtime route denial and the separate unprivileged service/process
  boundary; do not replace those checks with browser-only assertions.

For ordinary development and verification, use mocks and temporary directories.
Do not assume the current machine is a disposable Proxmox host.

## Testing

Run the complete local suite from the repository root:

```bash
./tailmox test
```

The equivalent command is:

```bash
bash tailmox test
```

When changing behavior:

- Add or update a focused `tests/test-*.sh` test.
- Mock external commands such as `tailscale`, `pvecm`, `systemctl`, `curl`, and
  Proxmox utilities.
- Redirect logs, binaries, and systemd paths to temporary directories.
- Cover success, command failure, malformed output, incomplete state, and
  unsafe-state rejection where relevant.
- Verify that guarded operations are not called when preconditions fail.
- Ensure temporary files are removed with a trap.

Do not require a live Tailscale account, Proxmox installation, root access, or
internet connection for the local test suite.

## Documentation

### Monitor page design

- New monitor pages and options must match the existing Monitor, ID, and Settings
  design: typography, colors, content width, spacing, controls, and top Page dropdown.
- Reuse `web/monitor-forms.css` for form pages. File templates use the
  `__MONITOR_FORM_STYLE__` placeholder, resolved with `MONITOR_FORM_STYLE` by the
  monitor handler. ID and Settings use this same stylesheet.
- Use the existing `page-picker`, `actions`, `field`, and form control patterns;
  do not introduce a separate palette or page shell for a new workflow.
- Include new destinations consistently in page navigation and preserve the
  `/monitor` and `/control` URL prefixes.
- Check desktop and mobile layouts and ensure existing confirmations still work.

Update `README.md` whenever commands, requirements, ports, ACL rules, supported
Proxmox versions, or user-visible behavior change.

Update `test-env/README.md` when test-environment workflows or parameters
change.

Update `VERSIONS.md` only when the change belongs to a planned release entry.

Keep examples consistent with the actual command interface:

```text
tailmox cluster
tailmox serve
tailmox stage
tailmox test
tailmox help
```

## Scope discipline

Keep changes focused on the requested behavior. Preserve unrelated user edits
and avoid broad formatting rewrites.

## Git authorization

After completing a code change, commit the files in scope, push the commit to
the configured remote, and deploy it to `pve-a2` by updating
`/opt/tailmox` to the pushed `dev` revision. This is the default unless the
user explicitly requests a local-only change or says not to deploy. Before a
host update, verify that its checkout is clean; do not overwrite host-local
changes without the user's explicit approval.

When the user asks to save or commit work to Git, that request pre-authorizes
staging the files in scope, creating the local commit, and pushing it to the
configured remote (generally GitHub) without a separate confirmation. Review
the staged diff first, preserve unrelated user changes, and never include
credentials or generated secrets.

Create a separate commit for each individual task. Stage only the files and
hunks produced for that task, and always leave unrelated working-tree changes
unstaged. Never commit the repository's entire set of pending changes together.

Do not otherwise push commits or modify a remote unless the user explicitly
requests it.

Before completing a change:

1. Run the relevant focused tests.
2. Run `./tailmox test`.
3. Review the diff for leaked credentials, hard-coded environment details,
   unsafe defaults, and unintended changes.
4. Clearly report any validation that could not be performed without a real
   Proxmox test environment.
