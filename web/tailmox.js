const backupList = document.querySelector("#backup-list");
const backupCount = document.querySelector("#backup-count");
const createBackupButton = document.querySelector("#create-backup");
const latestBackup = document.querySelector("#latest-backup");
const refreshButton = document.querySelector("#refresh-backups");
const reloadTerminalButton = document.querySelector("#reload-terminal");
const runClusterButton = document.querySelector("#run-cluster");
const runTestButton = document.querySelector("#run-test");
const terminal = document.querySelector("#terminal");
const backupTemplate = document.querySelector("#backup-template");
const monitorCluster = document.querySelector("#monitor-cluster");
const monitorDatabaseSize = document.querySelector("#monitor-database-size");
const monitorDescription = document.querySelector("#monitor-description");
const monitorHealth = document.querySelector("#monitor-health");
const monitorHistory = document.querySelector("#monitor-history");
const monitorIssueCount = document.querySelector("#monitor-issue-count");
const monitorLatestTime = document.querySelector("#monitor-latest-time");
const monitorMode = document.querySelector("#monitor-mode");
const monitorNodeCount = document.querySelector("#monitor-node-count");
const monitorNodes = document.querySelector("#monitor-nodes");
const monitorOnlineCount = document.querySelector("#monitor-online-count");
const monitorPassRate = document.querySelector("#monitor-pass-rate");
const monitorRunCount = document.querySelector("#monitor-run-count");
const monitorRunHeading = document.querySelector("#monitor-run-heading");
const monitorRunSummary = document.querySelector("#monitor-run-summary");
const monitorRunDialog = document.querySelector("#monitor-run-dialog");
const monitorDialogClose = document.querySelector("#monitor-dialog-close");
const monitorDialogIssueCount = document.querySelector("#monitor-dialog-issue-count");
const monitorDialogIssues = document.querySelector("#monitor-dialog-issues");
const monitorDialogNodeCount = document.querySelector("#monitor-dialog-node-count");
const monitorDialogNodes = document.querySelector("#monitor-dialog-nodes");
const monitorDialogSummary = document.querySelector("#monitor-dialog-summary");
const monitorState = document.querySelector("#monitor-state");
const monitorStateLabel = document.querySelector("#monitor-state-label");

document.querySelector("#host-name").textContent = window.location.hostname;

function formatMonitorTimestamp(value) {
    const parsed = new Date(value);
    if (Number.isNaN(parsed.getTime())) {
        return "Unknown time";
    }
    return new Intl.DateTimeFormat(undefined, {
        dateStyle: "medium",
        timeStyle: "short",
    }).format(parsed);
}

function formatMonitorMode(mode) {
    return mode === "cluster" ? "Cluster" : "Pre-cluster";
}

function formatByteSize(value) {
    const bytes = Number(value);
    if (!Number.isFinite(bytes) || bytes < 0) {
        return "Unavailable";
    }
    if (bytes < 1024) {
        return `${bytes} B`;
    }

    const units = ["KB", "MB", "GB", "TB"];
    let size = bytes / 1024;
    let unit = units[0];
    for (let index = 1; index < units.length && size >= 1024; index += 1) {
        size /= 1024;
        unit = units[index];
    }
    return `${size.toFixed(size >= 10 ? 1 : 2)} ${unit}`;
}

function renderMonitorHistory(history) {
    if (!history.length) {
        const empty = document.createElement("span");
        empty.className = "history-empty";
        empty.textContent = "No monitor runs recorded";
        monitorHistory.replaceChildren(empty);
        return;
    }

    const bars = history.map((run) => {
        const bar = document.createElement("button");
        bar.type = "button";
        bar.className = `history-run is-${run.status}`;
        bar.title = `${formatMonitorTimestamp(run.startedAt)} · ${run.status} · ${formatMonitorMode(run.mode)}`;
        bar.setAttribute("aria-label", bar.title);
        bar.addEventListener("click", () => {
            openMonitorRunDialog(run);
        });
        return bar;
    });
    monitorHistory.replaceChildren(...bars);
}

function formatMonitorDuration(value) {
    const milliseconds = Number(value);
    if (!Number.isFinite(milliseconds) || milliseconds < 0) {
        return "duration unavailable";
    }
    if (milliseconds < 1000) {
        return `${milliseconds} ms`;
    }
    return `${(milliseconds / 1000).toFixed(1)} s`;
}

function createMonitorNodeRows(run) {
    const nodes = Array.isArray(run.nodes) ? run.nodes : [];
    const issues = Array.isArray(run.issues) ? run.issues : [];
    const issueHosts = new Set(issues.map((issue) => issue.hostname).filter(Boolean));
    return nodes.map((node) => {
        const row = document.createElement("div");
        row.className = "node-row";

        const identity = document.createElement("div");
        const name = document.createElement("strong");
        const address = document.createElement("small");
        name.textContent = node.hostname;
        address.textContent = node.dnsName || node.tailscaleIp || "Address unavailable";
        identity.append(name, address);

        const badges = document.createElement("div");
        badges.className = "node-badges";
        if (node.local) {
            const localBadge = document.createElement("span");
            localBadge.className = "node-badge";
            localBadge.textContent = "Local";
            badges.append(localBadge);
        }
        const status = document.createElement("span");
        status.className = `node-badge ${node.online && !issueHosts.has(node.hostname) ? "is-online" : "is-issue"}`;
        status.textContent = !node.online
            ? "Offline"
            : issueHosts.has(node.hostname) ? "Issue" : "Healthy";
        badges.append(status);

        row.append(identity, badges);
        return row;
    });
}

function renderMonitorNodes(run) {
    const nodes = Array.isArray(run.nodes) ? run.nodes : [];
    const issues = Array.isArray(run.issues) ? run.issues : [];
    monitorRunHeading.textContent = "Run details";
    monitorRunSummary.textContent = [
        formatMonitorTimestamp(run.startedAt),
        formatMonitorMode(run.mode),
        run.status,
        formatMonitorDuration(run.durationMs),
    ].join(" · ");
    monitorNodeCount.textContent = String(nodes.length);
    monitorOnlineCount.textContent = `${nodes.filter((node) => node.online).length} online`;
    monitorIssueCount.textContent = `${issues.length} issue${issues.length === 1 ? "" : "s"}`;

    const rows = createMonitorNodeRows(run);
    if (!rows.length) {
        monitorNodes.textContent = "No Tailmox nodes were present in this snapshot.";
        return;
    }
    monitorNodes.replaceChildren(...rows);
}

function openMonitorRunDialog(run) {
    const nodes = Array.isArray(run.nodes) ? run.nodes : [];
    const issues = Array.isArray(run.issues) ? run.issues : [];
    monitorDialogSummary.textContent = [
        formatMonitorTimestamp(run.startedAt),
        formatMonitorMode(run.mode),
        run.status,
        formatMonitorDuration(run.durationMs),
    ].join(" · ");
    monitorDialogNodeCount.textContent = `${nodes.length} node${nodes.length === 1 ? "" : "s"}`;
    monitorDialogIssueCount.textContent = `${issues.length} issue${issues.length === 1 ? "" : "s"}`;

    const nodeRows = createMonitorNodeRows(run);
    monitorDialogNodes.replaceChildren(...nodeRows);
    if (!nodeRows.length) {
        monitorDialogNodes.textContent = "No Tailmox nodes were present in this snapshot.";
    }

    const issueRows = issues.map((issue) => {
        const row = document.createElement("div");
        row.className = "issue-row";
        const target = issue.hostname || "Host-wide check";
        const detail = issue.port
            ? `port ${issue.port}`
            : issue.packetSizeBytes ? `${issue.packetSizeBytes}-byte packet` : issue.name;
        row.textContent = `${target} · ${issue.category} · ${detail} · ${issue.status}`;
        return row;
    });
    monitorDialogIssues.replaceChildren(...issueRows);
    if (!issueRows.length) {
        monitorDialogIssues.textContent = "No issues were recorded for this run.";
    }
    monitorRunDialog.showModal();
}

monitorDialogClose.addEventListener("click", () => monitorRunDialog.close());
monitorRunDialog.addEventListener("click", (event) => {
    if (event.target === monitorRunDialog) {
        monitorRunDialog.close();
    }
});

function renderMonitor(analytics) {
    const totals = analytics.last24Hours || {};
    const runs = Number(totals.runs) || 0;
    const passed = Number(totals.passed) || 0;
    const latest = analytics.latest;
    const history = Array.isArray(analytics.history) ? analytics.history : [];

    monitorDatabaseSize.textContent = formatByteSize(analytics.databaseSizeBytes);
    monitorRunCount.textContent = String(runs);
    monitorPassRate.textContent = runs
        ? `${Math.round((passed / runs) * 100)}% passed · ${Number(totals.failed) || 0} failed`
        : "No history yet";
    renderMonitorHistory(history);

    if (!latest) {
        monitorHealth.textContent = "Waiting";
        monitorHealth.className = "";
        monitorLatestTime.textContent = "No result yet";
        monitorMode.textContent = "—";
        monitorCluster.textContent = "Detecting cluster state";
        monitorDescription.textContent = "The event stream is ready; waiting for the first test run.";
        monitorNodeCount.textContent = "0";
        monitorOnlineCount.textContent = "No snapshot yet";
        monitorIssueCount.textContent = "0 issues";
        monitorRunHeading.textContent = "Run details";
        monitorRunSummary.textContent = "";
        return;
    }

    monitorHealth.textContent = latest.status;
    monitorHealth.className = `health-${latest.status}`;
    monitorLatestTime.textContent = formatMonitorTimestamp(latest.finishedAt || latest.startedAt);
    monitorMode.textContent = formatMonitorMode(latest.mode);
    if (latest.clusterName && latest.cluster) {
        const quorumState = latest.cluster.quorate ? "quorate" : "quorum issue";
        const nodeTotal = Number(latest.cluster.configuredNodes);
        monitorCluster.textContent = `${latest.clusterName} · ${quorumState}`
            + (Number.isFinite(nodeTotal) ? ` · ${nodeTotal} nodes` : "");
    } else {
        monitorCluster.textContent = "Host preparation checks";
    }
    monitorDescription.textContent = latest.mode === "cluster"
        ? "Cluster-aware health, membership, quorum, and network history."
        : "Baseline Tailscale, ICMP, and Proxmox port health before clustering.";
    renderMonitorNodes(latest);
}

const monitorEvents = new EventSource("monitor/events");
monitorEvents.addEventListener("open", () => {
    monitorState.classList.add("is-connected");
    monitorStateLabel.textContent = "Live";
});
monitorEvents.addEventListener("error", () => {
    monitorState.classList.remove("is-connected");
    monitorStateLabel.textContent = "Monitor offline";
    monitorDescription.textContent = "Start tailmox monitor to stream health analytics.";
});
monitorEvents.addEventListener("analytics", (event) => {
    try {
        renderMonitor(JSON.parse(event.data));
    } catch {
        monitorDescription.textContent = "The monitor sent an unreadable analytics update.";
    }
});
monitorEvents.addEventListener("backups", (event) => {
    try {
        const inventory = JSON.parse(event.data);
        renderBackups(Array.isArray(inventory.backups) ? inventory.backups : []);
    } catch {
        backupCount.textContent = "—";
        latestBackup.textContent = "Unavailable";
    }
});

function parseBackupTimestamp(value) {
    const match = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/.exec(value);
    if (!match) {
        return null;
    }

    return new Date(Date.UTC(
        Number(match[1]),
        Number(match[2]) - 1,
        Number(match[3]),
        Number(match[4]),
        Number(match[5]),
        Number(match[6]),
    ));
}

function formatTimestamp(value) {
    const parsed = parseBackupTimestamp(value);
    if (!parsed) {
        return "Creation time unavailable";
    }

    return new Intl.DateTimeFormat(undefined, {
        dateStyle: "medium",
        timeStyle: "short",
    }).format(parsed);
}

function formatRelativeTimestamp(value) {
    const parsed = parseBackupTimestamp(value);
    if (!parsed) {
        return "Unknown";
    }

    const elapsedSeconds = Math.max(0, Math.floor((Date.now() - parsed.getTime()) / 1000));
    if (elapsedSeconds < 60) {
        return "Just now";
    }
    if (elapsedSeconds < 3600) {
        const minutes = Math.floor(elapsedSeconds / 60);
        return `${minutes} min ago`;
    }
    if (elapsedSeconds < 86400) {
        const hours = Math.floor(elapsedSeconds / 3600);
        return `${hours} hr${hours === 1 ? "" : "s"} ago`;
    }

    const days = Math.floor(elapsedSeconds / 86400);
    return `${days} day${days === 1 ? "" : "s"} ago`;
}

function formatBytes(bytes) {
    if (!Number.isFinite(bytes) || bytes < 0) {
        return "Unknown size";
    }

    const units = ["B", "KB", "MB", "GB"];
    let value = bytes;
    let unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
        value /= 1024;
        unitIndex += 1;
    }

    const digits = value >= 10 || unitIndex === 0 ? 0 : 1;
    return `${value.toFixed(digits)} ${units[unitIndex]}`;
}

function renderEmptyState() {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.textContent = "No Tailmox configuration backups have been created on this host yet.";
    backupList.replaceChildren(empty);
}

function renderBackups(backups) {
    backupCount.textContent = String(backups.length);

    if (backups.length === 0) {
        latestBackup.textContent = "None yet";
        renderEmptyState();
        return;
    }

    latestBackup.textContent = formatRelativeTimestamp(backups[0].createdAt);
    const cards = backups.map((backup) => {
        const card = backupTemplate.content.cloneNode(true);
        const status = card.querySelector(".status-badge");

        card.querySelector("h3").textContent = backup.type === "corosync"
            ? "Corosync configuration"
            : "Proxmox cluster configuration";
        card.querySelector(".backup-time").textContent = formatTimestamp(backup.createdAt);
        card.querySelector(".backup-size").textContent = formatBytes(backup.sizeBytes);
        card.querySelector(".backup-file").textContent = backup.filename;
        card.querySelector(".backup-file").title = backup.filename;
        status.textContent = backup.integrity === "valid" ? "Verified" : "Check failed";

        if (backup.integrity !== "valid") {
            status.classList.add("is-invalid");
        }

        return card;
    });

    backupList.replaceChildren(...cards);
}

async function loadBackups() {
    refreshButton.classList.add("is-refreshing");
    refreshButton.disabled = true;

    try {
        const response = await fetch(`backups.json?updated=${Date.now()}`, {
            cache: "no-store",
        });
        if (!response.ok) {
            throw new Error(`Backup inventory returned ${response.status}`);
        }

        const inventory = await response.json();
        renderBackups(Array.isArray(inventory.backups) ? inventory.backups : []);
    } catch {
        backupCount.textContent = "—";
        latestBackup.textContent = "Unavailable";
        const error = document.createElement("div");
        error.className = "error-state";
        error.textContent = "The backup inventory could not be read. Reload this page or check the Tailmox service.";
        backupList.replaceChildren(error);
    } finally {
        refreshButton.classList.remove("is-refreshing");
        refreshButton.disabled = false;
    }
}

refreshButton.addEventListener("click", loadBackups);
reloadTerminalButton.addEventListener("click", () => {
    terminal.src = `terminal/?reloaded=${Date.now()}`;
});
runTestButton.addEventListener("click", () => {
    terminal.src = `terminal/?arg=test&started=${Date.now()}`;
});
createBackupButton.addEventListener("click", () => {
    terminal.src = `terminal/?arg=backup-create&started=${Date.now()}`;
});
runClusterButton.addEventListener("click", () => {
    const confirmed = window.confirm(
        "Start the interactive Tailmox clustering workflow? "
        + "It can change networking and Proxmox cluster state after its built-in confirmations.",
    );
    if (confirmed) {
        terminal.src = `terminal/?arg=cluster&started=${Date.now()}`;
    }
});

loadBackups();
