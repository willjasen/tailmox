const backupList = document.querySelector("#backup-list");
const backupCount = document.querySelector("#backup-count");
const createBackupButton = document.querySelector("#create-backup");
const latestBackup = document.querySelector("#latest-backup");
const refreshButton = document.querySelector("#refresh-backups");
const reloadTerminalButton = document.querySelector("#reload-terminal");
const runClusterButton = document.querySelector("#run-cluster");
const runTestButton = document.querySelector("#run-test");
const terminalFrame = document.querySelector("#terminal-frame");
const terminal = document.querySelector("#terminal");
const backupTemplate = document.querySelector("#backup-template");
const monitorCluster = document.querySelector("#monitor-cluster");
const monitorDatabaseSize = document.querySelector("#monitor-database-size");
const monitorDescription = document.querySelector("#monitor-description");
const monitorHealth = document.querySelector("#monitor-health");
const monitorHistory = document.querySelector("#monitor-history");
const monitorIssueCount = document.querySelector("#monitor-issue-count");
const monitorLatencyChart = document.querySelector("#monitor-latency-chart");
const monitorLatencyEmpty = document.querySelector("#monitor-latency-empty");
const monitorLatencySummary = document.querySelector("#monitor-latency-summary");
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
const monitorDialogHostCount = document.querySelector("#monitor-dialog-host-count");
const monitorDialogHosts = document.querySelector("#monitor-dialog-hosts");
const monitorDialogIssueCount = document.querySelector("#monitor-dialog-issue-count");
const monitorDialogIssues = document.querySelector("#monitor-dialog-issues");
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

function formatLatency(value) {
    const latency = Number(value);
    if (!Number.isFinite(latency)) {
        return "unavailable";
    }
    return `${latency.toFixed(latency >= 100 ? 0 : latency >= 10 ? 1 : 2)} ms`;
}

function renderLatencyChart(history) {
    const chartRuns = history.slice(-60);
    const series = chartRuns.map((run) => ({
        run,
        average: run.latencyAverageMs === null || run.latencyAverageMs === undefined
            ? Number.NaN
            : Number(run.latencyAverageMs),
        maximum: run.latencyMaximumMs === null || run.latencyMaximumMs === undefined
            ? Number.NaN
            : Number(run.latencyMaximumMs),
    }));
    const values = series.flatMap((item) => [item.average, item.maximum])
        .filter((value) => Number.isFinite(value) && value >= 0);

    monitorLatencyChart.replaceChildren();
    if (!values.length) {
        monitorLatencyChart.hidden = true;
        monitorLatencyEmpty.hidden = false;
        monitorLatencySummary.textContent = "Waiting for latency measurements";
        return;
    }

    monitorLatencyChart.hidden = false;
    monitorLatencyEmpty.hidden = true;
    const latest = [...series].reverse().find((item) => (
        Number.isFinite(item.average) || Number.isFinite(item.maximum)
    ));
    monitorLatencySummary.textContent = latest
        ? `Latest · avg ${formatLatency(latest.average)} · max ${formatLatency(latest.maximum)}`
        : "Latency measurements unavailable";

    const namespace = "http://www.w3.org/2000/svg";
    const width = 900;
    const height = 220;
    const margin = {top: 18, right: 18, bottom: 28, left: 56};
    const plotWidth = width - margin.left - margin.right;
    const plotHeight = height - margin.top - margin.bottom;
    const highest = Math.max(...values);
    const ceiling = highest > 0 ? highest * 1.08 : 1;
    const xPosition = (index) => margin.left + (
        series.length === 1 ? plotWidth / 2 : (index / (series.length - 1)) * plotWidth
    );
    const yPosition = (value) => margin.top + plotHeight - (value / ceiling) * plotHeight;
    const makeSvgElement = (name, attributes = {}) => {
        const element = document.createElementNS(namespace, name);
        Object.entries(attributes).forEach(([key, value]) => {
            element.setAttribute(key, String(value));
        });
        return element;
    };

    for (let index = 0; index <= 4; index += 1) {
        const value = ceiling * (index / 4);
        const y = yPosition(value);
        const gridLine = makeSvgElement("line", {
            class: "latency-grid-line",
            x1: margin.left,
            x2: width - margin.right,
            y1: y,
            y2: y,
        });
        const label = makeSvgElement("text", {
            class: "latency-axis-label",
            x: margin.left - 9,
            y: y + 4,
            "text-anchor": "end",
        });
        label.textContent = formatLatency(value);
        monitorLatencyChart.append(gridLine, label);
    }

    const addSeries = (key, className, label) => {
        let pathData = "";
        let startSegment = true;
        series.forEach((item, index) => {
            const value = item[key];
            if (!Number.isFinite(value) || value < 0) {
                startSegment = true;
                return;
            }
            const x = xPosition(index);
            const y = yPosition(value);
            pathData += `${startSegment ? " M" : " L"} ${x.toFixed(2)} ${y.toFixed(2)}`;
            startSegment = false;
            const point = makeSvgElement("circle", {
                class: `latency-point ${className}`,
                cx: x,
                cy: y,
                r: 3.5,
            });
            const title = makeSvgElement("title");
            title.textContent = `${formatMonitorTimestamp(item.run.startedAt)} · ${label} ${formatLatency(value)}`;
            point.append(title);
            monitorLatencyChart.append(point);
        });
        if (pathData) {
            const path = makeSvgElement("path", {
                class: `latency-line ${className}`,
                d: pathData,
            });
            monitorLatencyChart.prepend(path);
        }
    };

    addSeries("maximum", "is-maximum", "maximum");
    addSeries("average", "is-average", "average");

    const oldestLabel = makeSvgElement("text", {
        class: "latency-axis-label",
        x: margin.left,
        y: height - 7,
        "text-anchor": "start",
    });
    oldestLabel.textContent = "Oldest";
    const newestLabel = makeSvgElement("text", {
        class: "latency-axis-label",
        x: width - margin.right,
        y: height - 7,
        "text-anchor": "end",
    });
    newestLabel.textContent = "Newest";
    monitorLatencyChart.append(oldestLabel, newestLabel);
    monitorLatencyChart.setAttribute(
        "aria-label",
        `Recent latency across ${series.length} monitor run${series.length === 1 ? "" : "s"}; `
        + `latest average ${formatLatency(latest?.average)}, latest maximum ${formatLatency(latest?.maximum)}.`,
    );
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
    const checks = Array.isArray(run.checks) ? run.checks : [];
    const failureReasons = Array.isArray(run.failureReasons) ? run.failureReasons : [];
    const issueCount = failureReasons.length;
    monitorDialogSummary.textContent = [
        formatMonitorTimestamp(run.startedAt),
        formatMonitorMode(run.mode),
        run.status,
        formatMonitorDuration(run.durationMs),
    ].join(" · ");
    monitorDialogHostCount.textContent = `${nodes.length} host${nodes.length === 1 ? "" : "s"} · ${checks.length} check${checks.length === 1 ? "" : "s"}`;
    monitorDialogIssueCount.textContent = `${issueCount} issue${issueCount === 1 ? "" : "s"}`;

    const createMeasurementRow = (check) => {
        const row = document.createElement("div");
        row.className = `measurement-row is-${check.status}`;
        const label = document.createElement("strong");
        const value = document.createElement("span");
        if (check.category === "tcp" && check.port) {
            label.textContent = `TCP ${check.port}`;
        } else if (check.category === "icmp" && check.packetSizeBytes) {
            label.textContent = `ICMP ${check.packetSizeBytes}-byte`;
        } else if (check.category === "tailscale") {
            label.textContent = "Tailscale path";
        } else {
            label.textContent = check.category;
        }
        const hasLatency = check.latencyAverageMs !== null
            && check.latencyAverageMs !== undefined
            && check.latencyMaximumMs !== null
            && check.latencyMaximumMs !== undefined;
        const latency = check.category === "tcp" || check.status === "failed"
            ? (check.status === "passed" ? "Passed" : "Failed")
            : hasLatency
                ? `avg ${Number(check.latencyAverageMs).toFixed(3)} ms · max ${Number(check.latencyMaximumMs).toFixed(3)} ms`
                : "latency unavailable";
        const packets = check.packetsSent !== null && check.packetsSent !== undefined
            ? ` · ${check.packetsReceived}/${check.packetsSent} replies`
            : "";
        const duration = check.durationSeconds !== null && check.durationSeconds !== undefined
            ? ` over ${check.durationSeconds}s`
            : "";
        value.textContent = `${latency}${packets}${duration}`;
        row.append(label, value);
        return row;
    };

    const issueHosts = new Set(issues.map((issue) => issue.hostname).filter(Boolean));
    const hostCards = nodes.map((node) => {
        const card = document.createElement("section");
        card.className = "host-check-card";
        const heading = document.createElement("div");
        heading.className = "host-check-heading";
        const identity = document.createElement("div");
        const name = document.createElement("h4");
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
        heading.append(identity, badges);

        const hostMeasurements = document.createElement("div");
        hostMeasurements.className = "host-measurements";
        const hostChecks = checks.filter((check) => check.hostname === node.hostname);
        hostMeasurements.replaceChildren(...hostChecks.map(createMeasurementRow));
        if (!hostChecks.length) {
            hostMeasurements.textContent = "No network checks recorded.";
        }
        card.append(heading, hostMeasurements);
        return card;
    });
    monitorDialogHosts.replaceChildren(...hostCards);
    if (!hostCards.length) {
        monitorDialogHosts.textContent = "No Tailmox hosts were present in this snapshot.";
    }

    const failureRows = failureReasons.map((reason) => {
        const row = document.createElement("div");
        row.className = "issue-row is-run-level";
        row.textContent = reason.detail || `${reason.category} · ${reason.name}`;
        return row;
    });
    monitorDialogIssues.replaceChildren(...failureRows);
    if (!issueCount) {
        monitorDialogIssues.textContent = "No run-level issues were recorded for this run.";
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
    renderLatencyChart(history);

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

function showTerminal(path) {
    terminalFrame.hidden = false;
    reloadTerminalButton.disabled = false;
    terminal.src = path;
}

reloadTerminalButton.addEventListener("click", () => {
    showTerminal(`terminal/?reloaded=${Date.now()}`);
});
runTestButton.addEventListener("click", () => {
    showTerminal(`terminal/?arg=test&started=${Date.now()}`);
});
createBackupButton.addEventListener("click", () => {
    showTerminal(`terminal/?arg=backup-create&started=${Date.now()}`);
});
runClusterButton.addEventListener("click", () => {
    const confirmed = window.confirm(
        "Start the interactive Tailmox clustering workflow? "
        + "It can change networking and Proxmox cluster state after its built-in confirmations.",
    );
    if (confirmed) {
        showTerminal(`terminal/?arg=cluster&started=${Date.now()}`);
    }
});

loadBackups();
