# Sonos — Installation

## Prerequisites

### 1. iotCloud SSID — required settings

Apply these settings to the SSID serving `iotCloud` (VLAN 10.4.20.0/24) in UniFi Network
**before** adding speakers. Wrong SSID settings cause split-brain topology regardless of
whether the firewall module is installed correctly.

| Setting | Value | Why |
|---|---|---|
| Network type | **Corporate** (NOT Guest) | Guest isolation breaks Sonos peer-to-peer |
| Fast roaming (802.11r) | **OFF** | Causes dropped sessions on speaker roam |
| BSS Transition / Band Steering | **OFF** | Bounces speakers between APs → dropouts |
| Min RSSI / client steering | **OFF** or ≤ −80 dBm | Kicks stationary wall-mounted speakers |
| Multicast Enhancement (IGMPv3) | **ON** | Converts multicast to unicast per AP — key cross-AP fix |
| Multicast & Broadcast filtering | **OFF** for iotCloud | Filtering kills Sonos topology sync |
| WPA mode | **WPA2-AES (CCMP) only** | Legacy Sonos doesn't support WPA3/mixed |
| IGMP snooping | **ON**, with IGMP querier on the VLAN | Controls flood without starving discovery |
| 2.4 GHz | Enabled, **HT20**, manual channels (floor 0→ch1 / floor 1→ch6 / floor 2→ch11) | Older Sonos prefer 2.4 GHz; non-overlapping channels per floor |
| Advanced IoT Connectivity | **ON** (if available) | Automatically handles multicast-to-unicast; disables Fast Roaming |

Source: [Ubiquiti Help Center — Best Practices for Sonos Devices](https://help.ui.com/hc/en-us/articles/18930473041047-Best-Practices-for-Sonos-Devices)

### 2. Transport mode decision

Before installing speakers, decide: **all-WiFi** or **multi-anchor SonosNet**? See README.md.
Never run one wired SonosNet anchor + everything else on WiFi across floors — this is the
split-brain configuration. Once decided, install speakers in that mode before adding DHCP
reservations.

### 3. Static DHCP reservations — one per speaker

Create a static reservation for each speaker's MAC address using the foundation tool:

```bash
# One command per speaker — --mac binds IP to MAC (DHCP + DNS locked together)
dns-manager --no-ssl-verify add <hostname> iotCloud.internal <ip> \
  --mac <mac> --description "Sonos <model>: <room>"

# Example fleet (adjust IPs and MACs to your deployment):
dns-manager --no-ssl-verify add sonos-livingroom     iotCloud.internal 10.4.20.10 \
  --mac 48:a6:b8:28:9c:e8 --description "Sonos Port: Livingroom"
dns-manager --no-ssl-verify add sonos-kitchen-eetf   iotCloud.internal 10.4.20.11 \
  --mac 78:28:ca:0d:14:34 --description "Sonos One: Kitchen Eettafel"
# ... repeat for remaining speakers
```

Get the MAC address for each speaker: Sonos S2 app → Settings → [speaker] → About.

**Verify reservations are saved:**
```bash
dns-manager --no-ssl-verify list | grep sonos
```

Each entry should show `hostname.iotCloud.internal -> IP`. If hardware_addr shows as None
in the Python library's list_hosts(), verify via OPNsense UI (Services → Dnsmasq DNS & DHCP →
Leases — entries tagged "static" with the correct MAC confirm the reservation is active).

Speakers pick up reserved IPs on next DHCP renewal (T1 = 50% of lease time, typically ~12h)
or when power-cycled.

## Install

```bash
cd /home/tappaas/Community/src/ErikDaniel007/entertainment/sonos
install-module.sh sonos
```

This configures:
- Firewall pass rules (1400/1443/4070/4444/7000 TCP; 7000–7100 UDP)
- mDNS relay: `iotCloud` ↔ `home` ↔ `srvHome`
- SSDP 1900 relay: `srvHome` → `iotCloud` (HA rediscovery after restart)

## Post-install

### Topology verify (SOAP check)

All speakers must report the same full household — this is the definitive health check.
Run from the TAPPaaS host:

```bash
python3 - <<'EOF'
import urllib.request, html, xml.etree.ElementTree as ET, re

FLEET = {
    '10.4.20.10': 'Livingroom',
    '10.4.20.11': 'Kitchen-L LF',
    # ... add your IPs
}
SOAP = '''<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetZoneGroupState xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1"></u:GetZoneGroupState></s:Body></s:Envelope>'''

for ip, name in FLEET.items():
    req = urllib.request.Request(
        f'http://{ip}:1400/ZoneGroupTopology/Control', data=SOAP.encode(),
        headers={'Content-Type': 'text/xml',
                 'SOAPACTION': '"urn:schemas-upnp-org:service:ZoneGroupTopology:1#GetZoneGroupState"'})
    resp = urllib.request.urlopen(req, timeout=5).read().decode()
    raw = re.search(r'<ZoneGroupState>(.*?)</ZoneGroupState>', resp, re.DOTALL)
    members = ET.fromstring(html.unescape(raw.group(1))).findall('.//ZoneGroupMember')
    ips = {re.search(r'http://([^:]+):', m.get('Location','')).group(1)
           for m in members if re.search(r'http://([^:]+):', m.get('Location',''))}
    n = len(ips)
    print(f"{'✅' if n == len(FLEET) else '⚠️ '} {ip} ({name}): {n}/{len(FLEET)}")
EOF
```

Expected: all speakers return the full fleet count. Any speaker returning fewer = split-brain
(see Troubleshooting below).

### Home Assistant

Go to Settings → Devices & Services → Add integration → Sonos. Speakers auto-discover;
no manual host entry needed. Verify entity count matches fleet size.

## Verification

```bash
test-module.sh sonos
```

Manual checks:

| Check | Expected |
|---|---|
| Sonos S2 app on home WiFi | All speakers visible and playable |
| AirPlay from iPhone/Mac on home WiFi | All speakers appear as AirPlay targets |
| HA `media_player.sonos_*` entities | Available, count = fleet size |
| ZoneGroupTopology SOAP (see above) | Every speaker reports full fleet |

## Troubleshooting

**"Product not connected" / split-brain (speaker reports fewer than full fleet)**

One speaker has lost consistent topology sync with the rest. This is a network/transport
issue, not a module/firewall issue — the module's firewall rules apply to the whole `iotCloud`
alias and cannot selectively affect one speaker.

Checklist:
1. Confirm the speaker's reserved IP is active: `curl http://<ip>:1400/xml/device_description.xml`
2. Verify switch port profile (wired speaker): must be on `iotCloud` VLAN, not `guest` or other
3. Check iotCloud SSID settings — especially Multicast Enhancement ON and Fast Roaming OFF
4. If on SonosNet with only one wired anchor across multiple floors: this is the root cause —
   add a second wired anchor on the floor with the failing speaker, OR migrate all speakers to
   WiFi mode (see README.md transport section and TAR)
5. Full re-triage: `doc/sonos-network-transport-tar.md` §7 verification steps

**Sonos app does not find speakers from home WiFi**
Verify mDNS relay: `firewall:discovery test-service.sh sonos` — relay should be present.

**AirPlay audio drops after ~10 seconds**
Verify UDP 7000–7100 rules: `test-module.sh sonos` — no failures. If missing: `install-module.sh sonos --force`.

**Speaker replaced or added**
Add a static DHCP reservation via `dns-manager --no-ssl-verify add <hostname> iotCloud.internal <ip> --mac <mac>`.
No module reinstall needed.

**HA shows speakers unavailable after restart**
SSDP 1900 relay `srvHome → iotCloud` must be present (added in v0.2.0). Run
`firewall:discovery test-service.sh sonos`; if missing, `install-module.sh sonos --force`.
