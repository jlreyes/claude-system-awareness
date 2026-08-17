#!/usr/bin/env python3
"""Render bounded device, network, and Tailscale context for the hook."""

from __future__ import annotations

import datetime as dt
import json
import os
import sys
import unicodedata
from pathlib import Path
from typing import Any


SEPARATOR = "\x1f"
DEFAULT_METERED_GUIDANCE = (
    "Conserve bandwidth: avoid large downloads/uploads, dependency refreshes, "
    "container pulls, and redundant remote calls unless they are required."
)


def safe_label(value: Any, limit: int = 120) -> str:
    """Make machine-controlled labels safe and compact inside prompt markup."""
    if not isinstance(value, str):
        return ""
    normalized = unicodedata.normalize("NFC", value)
    cleaned = "".join(
        character
        for character in normalized
        if unicodedata.category(character) not in {"Cc", "Cs"}
    )
    cleaned = " ".join(cleaned.split())
    cleaned = cleaned.replace("<", "‹").replace(">", "›").replace('"', "'")
    return cleaned[:limit]


def load_json(path: str) -> dict[str, Any]:
    if not path:
        return {}
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def load_stdin_json() -> dict[str, Any]:
    try:
        value = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        return {}
    return value if isinstance(value, dict) else {}


def casefold_map(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        return {}
    return {str(key).casefold(): item for key, item in value.items()}


def first_ipv4(addresses: Any) -> str:
    if not isinstance(addresses, list):
        return ""
    values = [safe_label(address, 64) for address in addresses]
    return next((address for address in values if "." in address), values[0] if values else "")


def dns_short(peer: dict[str, Any]) -> str:
    dns_name = safe_label(peer.get("DNSName"), 160).rstrip(".")
    if dns_name:
        return dns_name.split(".", 1)[0]
    return safe_label(peer.get("HostName"), 120)


def device_profile(
    config: dict[str, Any], tailscale: dict[str, Any]
) -> tuple[str, str, str]:
    computer_name = safe_label(os.environ.get("NUDGE_COMPUTER_NAME"))
    local_host_name = safe_label(os.environ.get("NUDGE_LOCAL_HOST_NAME"))
    battery_present = os.environ.get("NUDGE_BATTERY_PRESENT") == "1"
    self_status = tailscale.get("Self") if isinstance(tailscale.get("Self"), dict) else {}
    self_host = safe_label(self_status.get("HostName"))

    devices = casefold_map(config.get("devices"))
    selected: Any = None
    for candidate in (computer_name, local_host_name, self_host):
        if candidate and candidate.casefold() in devices:
            selected = devices[candidate.casefold()]
            break

    role = ""
    fixed_location = ""
    if isinstance(selected, str):
        role = safe_label(selected, 60)
    elif isinstance(selected, dict):
        role = safe_label(selected.get("role"), 60)
        fixed_location = safe_label(selected.get("location"), 60)

    if not role:
        name_blob = " ".join((computer_name, local_host_name, self_host)).casefold()
        if battery_present or "macbook" in name_blob:
            role = "laptop"
        elif "studio" in name_blob:
            role = "Mac Studio"
        else:
            role = "Mac"

    display_name = computer_name or self_host or local_host_name or "this Mac"
    return display_name, role, fixed_location


def network_profile(
    config: dict[str, Any], fixed_location: str
) -> tuple[str, str, str, str]:
    ssid = safe_label(os.environ.get("NUDGE_SSID"))
    default_interface = safe_label(os.environ.get("NUDGE_DEFAULT_INTERFACE"), 40)
    wifi_interface = safe_label(os.environ.get("NUDGE_WIFI_INTERFACE"), 40)
    profiles = casefold_map(config.get("networkProfiles"))
    selected = profiles.get(ssid.casefold()) if ssid else None

    location = fixed_location
    bandwidth = "normal"
    guidance = ""
    if isinstance(selected, str):
        location = safe_label(selected, 60)
    elif isinstance(selected, dict):
        location = safe_label(selected.get("location"), 60) or location
        if selected.get("metered") is True:
            bandwidth = "metered"
        else:
            configured_bandwidth = safe_label(selected.get("bandwidth"), 30).casefold()
            if configured_bandwidth in {"metered", "constrained", "normal"}:
                bandwidth = configured_bandwidth
        guidance = safe_label(selected.get("guidance"), 280)

    if not guidance and bandwidth in {"metered", "constrained"}:
        guidance = DEFAULT_METERED_GUIDANCE

    if ssid:
        connection = f'Wi-Fi "{ssid}"'
    elif default_interface and default_interface != wifi_interface:
        connection = "wired/non-Wi-Fi network"
    else:
        connection = "no Wi-Fi"

    location_text = location or "location unknown"
    return location, bandwidth, guidance, f"{location_text} via {connection}"


def parse_last_seen(value: Any) -> str:
    raw = safe_label(value, 80)
    if not raw or raw.startswith("0001-"):
        return ""
    try:
        parsed = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return raw
    return parsed.astimezone(dt.timezone.utc).strftime("%Y-%m-%d %H:%MZ")


def tailscale_profile(
    config: dict[str, Any], tailscale: dict[str, Any]
) -> tuple[str, str]:
    if not tailscale:
        return "Tailscale unavailable", "unavailable"

    backend = safe_label(tailscale.get("BackendState"), 40) or "unknown"
    self_status = tailscale.get("Self") if isinstance(tailscale.get("Self"), dict) else {}
    self_ip = first_ipv4(self_status.get("TailscaleIPs"))
    self_dns = dns_short(self_status)
    self_identities = {
        safe_label(self_status.get("HostName")).casefold(),
        safe_label(self_status.get("DNSName"), 160).rstrip(".").casefold(),
        self_dns.casefold(),
    }
    if backend.casefold() != "running":
        return f"Tailscale not running ({backend})", f"backend:{backend.casefold()}"

    summary_parts = [f"local {self_dns or 'device'}{f' / {self_ip}' if self_ip else ''}"]
    state_parts = [f"self:{self_dns}:{self_ip}"]

    raw_peers = tailscale.get("Peer", {})
    if isinstance(raw_peers, dict):
        peers = [peer for peer in raw_peers.values() if isinstance(peer, dict)]
    elif isinstance(raw_peers, list):
        peers = [peer for peer in raw_peers if isinstance(peer, dict)]
    else:
        peers = []

    tracked = casefold_map(config.get("tailscalePeers"))
    for match, configured in tracked.items():
        if match in self_identities:
            continue
        if isinstance(configured, str):
            label = safe_label(configured, 60)
        elif isinstance(configured, dict):
            label = safe_label(configured.get("label"), 60)
        else:
            label = ""
        label = label or safe_label(match, 60)

        peer = next(
            (
                item
                for item in peers
                if match
                in {
                    safe_label(item.get("HostName")).casefold(),
                    safe_label(item.get("DNSName"), 160).rstrip(".").casefold(),
                    dns_short(item).casefold(),
                }
            ),
            None,
        )
        if peer is None:
            summary_parts.append(f"{label} absent from peer list")
            state_parts.append(f"{match}:absent")
            continue

        peer_ip = first_ipv4(peer.get("TailscaleIPs"))
        peer_dns = dns_short(peer)
        online = peer.get("Online") is True
        active = peer.get("Active") is True
        if online:
            status = "online, active" if active else "online"
        else:
            last_seen = parse_last_seen(peer.get("LastSeen"))
            status = f"offline, last seen {last_seen}" if last_seen else "offline"
        address = " / ".join(part for part in (peer_dns, peer_ip) if part)
        summary_parts.append(f"{label} {status}{f' at {address}' if address else ''}")
        state_parts.append(
            f"{match}:{'online' if online else 'offline'}:{'active' if active else 'idle'}:"
            f"{peer_dns}:{peer_ip}:{safe_label(peer.get('LastSeen'), 80)}"
        )

    return "Tailscale: " + "; ".join(summary_parts), "|".join(state_parts)


def main() -> int:
    config = load_json(sys.argv[1] if len(sys.argv) > 1 else "")
    tailscale = load_stdin_json()
    device_name, device_role, fixed_location = device_profile(config, tailscale)
    location, bandwidth, guidance, network_context = network_profile(config, fixed_location)
    tailscale_summary, tailscale_state = tailscale_profile(config, tailscale)

    fields = (
        device_name,
        device_role,
        location,
        bandwidth,
        guidance,
        network_context,
        tailscale_summary,
        tailscale_state,
    )
    print(SEPARATOR.join(safe_label(field, 700) for field in fields))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
