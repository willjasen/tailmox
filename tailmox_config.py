#!/usr/bin/env python3
"""Encrypted, host-approved Tailmox configuration storage."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import pathlib
import secrets
import socket
import subprocess
import tempfile
import threading
from typing import Any


PVE_CONFIG_DIR = pathlib.Path(os.environ.get("TAILMOX_PVE_CONFIG_DIR", "/etc/pve"))
CLUSTER_DIR = pathlib.Path(
    os.environ.get("TAILMOX_CONFIG_DIR", str(PVE_CONFIG_DIR / "tailmox"))
)
CONFIG_FILE = pathlib.Path(
    os.environ.get("TAILMOX_CONFIG_FILE", str(CLUSTER_DIR / "config.age"))
)
SECURITY_FILE = pathlib.Path(
    os.environ.get("TAILMOX_SECURITY_FILE", str(CLUSTER_DIR / "security.json"))
)
PROPOSALS_DIR = pathlib.Path(
    os.environ.get("TAILMOX_PROPOSALS_DIR", str(CLUSTER_DIR / "proposals"))
)
STATE_FILE = pathlib.Path(
    os.environ.get("TAILMOX_STATE_FILE", str(CLUSTER_DIR / "state.json"))
)
IDENTITY_FILE = pathlib.Path(
    os.environ.get("TAILMOX_AGE_IDENTITY_FILE", "/etc/tailmox/identity.txt")
)
SIGNING_KEY_FILE = pathlib.Path(
    os.environ.get("TAILMOX_SIGNING_KEY_FILE", "/etc/tailmox/signing-key.pem")
)
AGE_COMMAND = os.environ.get("TAILMOX_AGE_COMMAND", "age")
AGE_KEYGEN_COMMAND = os.environ.get("TAILMOX_AGE_KEYGEN_COMMAND", "age-keygen")
OPENSSL_COMMAND = os.environ.get("TAILMOX_OPENSSL_COMMAND", "openssl")
HOSTNAME = os.environ.get("TAILMOX_HOSTNAME", socket.gethostname())
LOCK = threading.RLock()


class ConfigError(RuntimeError):
    """A configuration operation failed closed."""


def utc_now() -> str:
    return (
        dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n").encode()


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def is_cluster_path(path: pathlib.Path) -> bool:
    try:
        path.resolve().relative_to(CLUSTER_DIR.resolve())
    except ValueError:
        return False
    return True


def run(command: list[str], *, input_value: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(
            command,
            input=input_value,
            check=True,
            capture_output=True,
            timeout=20,
        )
    except FileNotFoundError as error:
        raise ConfigError(f"Required command is unavailable: {command[0]}") from error
    except subprocess.TimeoutExpired as error:
        raise ConfigError(f"Command timed out: {command[0]}") from error
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode(errors="replace").strip()
        raise ConfigError(detail or f"Command failed: {command[0]}") from error


def atomic_write(path: pathlib.Path, value: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as temporary:
            descriptor = -1
            if not is_cluster_path(path):
                os.fchmod(temporary.fileno(), mode)
            temporary.write(value)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_name, path)
        if not is_cluster_path(path):
            os.chmod(path, mode)
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary_name)
        except OSError:
            pass
        raise


def read_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ConfigError(f"Missing Tailmox file: {path}") from error
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ConfigError(f"Invalid Tailmox file: {path}") from error
    if not isinstance(value, dict):
        raise ConfigError(f"Invalid Tailmox document: {path}")
    return value


def identity_secret(identity_text: str) -> str:
    found = [
        line.strip()
        for line in identity_text.splitlines()
        if line.strip().startswith("AGE-SECRET-KEY-")
    ]
    if len(found) != 1:
        raise ConfigError("Enter exactly one native age identity.")
    return found[0]


def age_recipient(identity_path: pathlib.Path = IDENTITY_FILE) -> str:
    recipient = run([AGE_KEYGEN_COMMAND, "-y", str(identity_path)]).stdout.decode().strip()
    if not recipient.startswith("age1"):
        raise ConfigError("The identity did not produce a native age recipient.")
    return recipient


def security_document() -> dict[str, Any]:
    if not SECURITY_FILE.exists():
        return {"schemaVersion": 1, "ageRecipient": None, "hosts": {}}
    document = read_json(SECURITY_FILE)
    if document.get("schemaVersion") != 1 or not isinstance(document.get("hosts"), dict):
        raise ConfigError("The Tailmox security registry is unsupported.")
    return document


def configured_cluster_hosts() -> set[str]:
    if not STATE_FILE.exists():
        return set()
    state = read_json(STATE_FILE)
    members = state.get("members", state.get("hosts", []))
    if not isinstance(members, list):
        raise ConfigError("The Tailmox cluster membership record is invalid.")
    return {
        str(member.get("name", member.get("hostname", "")))
        for member in members
        if isinstance(member, dict) and member.get("name", member.get("hostname"))
    }


def install_identity(identity_text: str) -> dict[str, Any]:
    secret = identity_secret(identity_text)
    with LOCK:
        IDENTITY_FILE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor, candidate_name = tempfile.mkstemp(
            prefix=".identity-candidate.", dir=IDENTITY_FILE.parent
        )
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "wb") as candidate:
                candidate.write(f"{secret}\n".encode())
                candidate.flush()
                os.fsync(candidate.fileno())
            recipient = age_recipient(pathlib.Path(candidate_name))
            security = security_document()
            expected = security.get("ageRecipient")
            if expected and expected != recipient:
                raise ConfigError("This age identity does not unlock this Tailmox cluster.")
            atomic_write(IDENTITY_FILE, f"{secret}\n".encode())
            if not expected:
                security["ageRecipient"] = recipient
                atomic_write(SECURITY_FILE, canonical_json(security), 0o644)
        finally:
            pathlib.Path(candidate_name).unlink(missing_ok=True)
    return {"recipient": recipient}


def create_identity() -> dict[str, Any]:
    if security_document().get("ageRecipient"):
        raise ConfigError("This cluster already has a Tailmox age identity; add that identity instead.")
    if IDENTITY_FILE.is_file():
        try:
            secret = identity_secret(IDENTITY_FILE.read_text(encoding="utf-8"))
        except (OSError, UnicodeError) as error:
            raise ConfigError("The incomplete local Tailmox identity cannot be recovered.") from error
    else:
        try:
            generated = run([AGE_KEYGEN_COMMAND, "-pq"]).stdout.decode()
        except ConfigError as error:
            raise ConfigError(
                "Tailmox requires age 1.3.0 or newer to create a post-quantum identity."
            ) from error
        secret = identity_secret(generated)
    if not secret.startswith("AGE-SECRET-KEY-PQ-1"):
        raise ConfigError("age-keygen did not create a post-quantum Tailmox identity.")
    result = install_identity(secret)
    if not result["recipient"].startswith("age1pq1"):
        raise ConfigError("The generated Tailmox recipient is not post-quantum.")
    result["identity"] = secret
    return result


def ensure_signing_key() -> str:
    if not SIGNING_KEY_FILE.exists():
        private_key = run(
            [OPENSSL_COMMAND, "genpkey", "-algorithm", "ED25519"]
        ).stdout
        atomic_write(SIGNING_KEY_FILE, private_key, 0o600)
    private_key = SIGNING_KEY_FILE.read_bytes()
    public_key = run(
        [OPENSSL_COMMAND, "pkey", "-pubout"], input_value=private_key
    ).stdout.decode("ascii")
    if "BEGIN PUBLIC KEY" not in public_key or "END PUBLIC KEY" not in public_key:
        raise ConfigError("The Tailmox host signing key is invalid.")
    return public_key


def enroll_local_host() -> dict[str, Any]:
    with LOCK:
        public_key = ensure_signing_key()
        security = security_document()
        hosts = security["hosts"]
        existing = hosts.get(HOSTNAME)
        if existing and existing.get("signingKey") != public_key:
            raise ConfigError("This host name is already registered with another signing key.")
        cluster_hosts = configured_cluster_hosts()
        if hosts and cluster_hosts and HOSTNAME not in cluster_hosts:
            raise ConfigError("This host is not present in Tailmox cluster membership.")
        if not existing:
            hosts[HOSTNAME] = {"signingKey": public_key, "enrolledAt": utc_now()}
            atomic_write(SECURITY_FILE, canonical_json(security), 0o644)
        return hosts[HOSTNAME]


def identity_status() -> dict[str, Any]:
    security = security_document()
    local_recipient = age_recipient() if IDENTITY_FILE.is_file() else None
    return {
        "configured": bool(local_recipient),
        "matchesCluster": bool(local_recipient and local_recipient == security.get("ageRecipient")),
        "postQuantum": bool(local_recipient and local_recipient.startswith("age1pq1")),
        "recipient": security.get("ageRecipient"),
        "recipientFingerprint": sha256(local_recipient.encode())[:16] if local_recipient else None,
        "host": HOSTNAME,
        "signingKeyConfigured": SIGNING_KEY_FILE.is_file(),
        "trustedHosts": sorted(security["hosts"]),
    }


def encrypt_config(document: dict[str, Any]) -> bytes:
    security = security_document()
    recipient = security.get("ageRecipient")
    if not recipient or age_recipient() != recipient:
        raise ConfigError("This host does not have the Tailmox cluster age identity.")
    return run([AGE_COMMAND, "--recipient", recipient], input_value=canonical_json(document)).stdout


def decrypt_config(ciphertext: bytes) -> dict[str, Any]:
    if not IDENTITY_FILE.is_file():
        raise ConfigError("Add the Tailmox cluster age identity on this host first.")
    plaintext = run(
        [AGE_COMMAND, "--decrypt", "--identity", str(IDENTITY_FILE)],
        input_value=ciphertext,
    ).stdout
    try:
        document = json.loads(plaintext.decode())
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ConfigError("The decrypted Tailmox configuration is invalid.") from error
    if not isinstance(document, dict) or document.get("schemaVersion") != 1:
        raise ConfigError("The Tailmox configuration schema is unsupported.")
    if not isinstance(document.get("influxdb"), dict):
        raise ConfigError("The Tailmox InfluxDB configuration is invalid.")
    return document


def current_config() -> dict[str, Any]:
    if not CONFIG_FILE.exists():
        return {
            "schemaVersion": 1,
            "revision": 0,
            "influxdb": {"url": "", "token": "", "org": "", "bucket": ""},
        }
    ciphertext = CONFIG_FILE.read_bytes()
    ciphertext_hash = sha256(ciphertext)
    if not PROPOSALS_DIR.is_dir():
        raise ConfigError("The active Tailmox configuration has no signed proposal history.")
    for directory in PROPOSALS_DIR.iterdir():
        if not directory.is_dir() or not (directory / "activated.json").is_file():
            continue
        try:
            manifest = read_json(directory / "manifest.json")
        except ConfigError:
            continue
        if manifest.get("ciphertextSha256") != ciphertext_hash:
            continue
        status = proposal_status(directory.name)
        if not status["ready"]:
            continue
        document = decrypt_config(ciphertext)
        if document.get("revision") != manifest.get("revision"):
            raise ConfigError("The active Tailmox configuration revision was modified.")
        return document
    raise ConfigError("The active Tailmox configuration lacks unanimous signed approval.")


def sign(value: bytes) -> bytes:
    ensure_signing_key()
    descriptor, value_name = tempfile.mkstemp(prefix="tailmox-signing-input.")
    try:
        os.write(descriptor, value)
        os.close(descriptor)
        return run(
            [
                OPENSSL_COMMAND,
                "pkeyutl",
                "-sign",
                "-rawin",
                "-inkey",
                str(SIGNING_KEY_FILE),
                "-in",
                value_name,
            ]
        ).stdout
    finally:
        pathlib.Path(value_name).unlink(missing_ok=True)


def verify(host: str, value: bytes, signature: bytes) -> None:
    security = security_document()
    host_record = security["hosts"].get(host)
    if not host_record:
        raise ConfigError(f"Unknown Tailmox signing host: {host}")
    public_key = str(host_record.get("signingKey", "")).encode()
    descriptor, public_name = tempfile.mkstemp(prefix="tailmox-public-key.")
    signature_descriptor, signature_name = tempfile.mkstemp(prefix="tailmox-signature.")
    value_descriptor, value_name = tempfile.mkstemp(prefix="tailmox-signing-input.")
    try:
        os.write(descriptor, public_key)
        os.close(descriptor)
        os.write(signature_descriptor, signature)
        os.close(signature_descriptor)
        os.write(value_descriptor, value)
        os.close(value_descriptor)
        run(
            [
                OPENSSL_COMMAND,
                "pkeyutl",
                "-verify",
                "-pubin",
                "-inkey",
                public_name,
                "-rawin",
                "-in",
                value_name,
                "-sigfile",
                signature_name,
            ]
        )
    finally:
        pathlib.Path(public_name).unlink(missing_ok=True)
        pathlib.Path(signature_name).unlink(missing_ok=True)
        pathlib.Path(value_name).unlink(missing_ok=True)


def proposal_path(proposal_id: str) -> pathlib.Path:
    if not proposal_id or any(character not in "abcdefghijklmnopqrstuvwxyz0123456789-" for character in proposal_id):
        raise ConfigError("Invalid Tailmox proposal identifier.")
    return PROPOSALS_DIR / proposal_id


def proposal_payload(directory: pathlib.Path) -> tuple[dict[str, Any], bytes, bytes]:
    manifest = read_json(directory / "manifest.json")
    ciphertext = (directory / "config.age").read_bytes()
    signed_value = canonical_json(manifest) + ciphertext
    signature = (directory / "proposal.sig").read_bytes()
    if manifest.get("ciphertextSha256") != sha256(ciphertext):
        raise ConfigError("The proposed encrypted configuration was modified.")
    verify(str(manifest.get("proposer", "")), signed_value, signature)
    return manifest, ciphertext, signed_value


def write_receipt(directory: pathlib.Path, proposal_id: str, decision: str) -> dict[str, Any]:
    manifest = read_json(directory / "manifest.json")
    receipt = {
        "schemaVersion": 1,
        "proposalId": proposal_id,
        "revision": manifest.get("revision"),
        "ciphertextSha256": manifest.get("ciphertextSha256"),
        "host": HOSTNAME,
        "decision": decision,
        "decidedAt": utc_now(),
    }
    receipts = directory / "receipts"
    atomic_write(receipts / f"{HOSTNAME}.json", canonical_json(receipt), 0o644)
    atomic_write(receipts / f"{HOSTNAME}.sig", sign(canonical_json(receipt)), 0o644)
    return receipt


def propose_config(document: dict[str, Any], summary: str) -> dict[str, Any]:
    with LOCK:
        enroll_local_host()
        current = current_config()
        document = dict(document)
        document["schemaVersion"] = 1
        document["revision"] = int(current.get("revision", 0)) + 1
        ciphertext = encrypt_config(document)
        proposal_id = f"{document['revision']}-{secrets.token_hex(8)}"
        directory = proposal_path(proposal_id)
        if directory.exists():
            raise ConfigError("The generated Tailmox proposal already exists.")
        manifest = {
            "schemaVersion": 1,
            "proposalId": proposal_id,
            "revision": document["revision"],
            "proposer": HOSTNAME,
            "createdAt": utc_now(),
            "ciphertextSha256": sha256(ciphertext),
            "requiredHosts": sorted(security_document()["hosts"]),
            "summary": summary.strip()[:240],
        }
        directory.mkdir(mode=0o700, parents=True)
        atomic_write(directory / "config.age", ciphertext, 0o644)
        atomic_write(directory / "manifest.json", canonical_json(manifest), 0o644)
        atomic_write(directory / "proposal.sig", sign(canonical_json(manifest) + ciphertext), 0o644)
        write_receipt(directory, proposal_id, "accepted")
        status = proposal_status(proposal_id)
        if status["ready"]:
            activation = {
                "proposalId": proposal_id,
                "revision": manifest["revision"],
                "activatedAt": utc_now(),
            }
            atomic_write(directory / "activated.json", canonical_json(activation), 0o644)
            atomic_write(CONFIG_FILE, ciphertext, 0o644)
            status["activated"] = True
        else:
            status["activated"] = False
        return status


def receipt_status(directory: pathlib.Path, manifest: dict[str, Any], host: str) -> str | None:
    receipt_path = directory / "receipts" / f"{host}.json"
    signature_path = directory / "receipts" / f"{host}.sig"
    if not receipt_path.is_file() or not signature_path.is_file():
        return None
    receipt = read_json(receipt_path)
    verify(host, canonical_json(receipt), signature_path.read_bytes())
    if (
        receipt.get("host") != host
        or receipt.get("proposalId") != manifest.get("proposalId")
        or receipt.get("revision") != manifest.get("revision")
        or receipt.get("ciphertextSha256") != manifest.get("ciphertextSha256")
    ):
        raise ConfigError("A Tailmox receipt is not bound to this exact proposal.")
    return str(receipt.get("decision"))


def proposal_status(proposal_id: str) -> dict[str, Any]:
    directory = proposal_path(proposal_id)
    manifest, ciphertext, _signed = proposal_payload(directory)
    if manifest.get("proposalId") != proposal_id:
        raise ConfigError("The Tailmox proposal identifier was modified.")
    decrypt_config(ciphertext)
    hosts = manifest.get("requiredHosts")
    if not isinstance(hosts, list) or not hosts or any(not isinstance(host, str) for host in hosts):
        raise ConfigError("The Tailmox proposal has an invalid approval set.")
    registered_hosts = security_document()["hosts"]
    if any(host not in registered_hosts for host in hosts):
        raise ConfigError("The Tailmox proposal references an unknown signing host.")
    receipts = {host: receipt_status(directory, manifest, host) for host in hosts}
    return {
        **manifest,
        "receipts": receipts,
        "ready": bool(hosts) and all(value == "accepted" for value in receipts.values()),
        "rejected": any(value == "rejected" for value in receipts.values()),
    }


def decide_proposal(proposal_id: str, decision: str) -> dict[str, Any]:
    if decision not in ("accepted", "rejected"):
        raise ConfigError("A Tailmox proposal can only be accepted or rejected.")
    with LOCK:
        enroll_local_host()
        directory = proposal_path(proposal_id)
        manifest, ciphertext, _signed = proposal_payload(directory)
        required_hosts = manifest.get("requiredHosts", [])
        if HOSTNAME not in required_hosts:
            raise ConfigError("This host is not an approver for this Tailmox proposal.")
        proposed = decrypt_config(ciphertext)
        current = current_config()
        if int(proposed.get("revision", -1)) != int(current.get("revision", 0)) + 1:
            raise ConfigError("This proposal is based on an obsolete configuration revision.")
        write_receipt(directory, proposal_id, decision)
        status = proposal_status(proposal_id)
        if status["ready"]:
            activation = {
                "proposalId": proposal_id,
                "revision": manifest["revision"],
                "activatedAt": utc_now(),
            }
            atomic_write(directory / "activated.json", canonical_json(activation), 0o644)
            atomic_write(CONFIG_FILE, ciphertext, 0o644)
            status["activated"] = True
        else:
            status["activated"] = False
        return status


def list_proposals() -> list[dict[str, Any]]:
    if not PROPOSALS_DIR.is_dir():
        return []
    results = []
    for directory in sorted(PROPOSALS_DIR.iterdir(), reverse=True):
        if not directory.is_dir():
            continue
        try:
            status = proposal_status(directory.name)
            status["activated"] = (directory / "activated.json").is_file()
            results.append(status)
        except ConfigError as error:
            results.append({"proposalId": directory.name, "error": str(error)})
    return results


def public_config() -> dict[str, Any]:
    document = current_config()
    influx = document["influxdb"]
    return {
        "schemaVersion": 1,
        "revision": document.get("revision", 0),
        "influxdb": {
            "url": influx.get("url", ""),
            "org": influx.get("org", ""),
            "bucket": influx.get("bucket", ""),
            "tokenConfigured": bool(influx.get("token")),
        },
    }
