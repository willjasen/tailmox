const backupList = document.querySelector("#backup-list");
const backupCount = document.querySelector("#backup-count");
const latestBackup = document.querySelector("#latest-backup");
const refreshButton = document.querySelector("#refresh-backups");
const reloadTerminalButton = document.querySelector("#reload-terminal");
const terminal = document.querySelector("#terminal");
const backupTemplate = document.querySelector("#backup-template");

document.querySelector("#host-name").textContent = window.location.hostname;

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

loadBackups();
window.setInterval(loadBackups, 30000);
