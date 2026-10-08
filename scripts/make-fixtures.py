#!/usr/bin/env python3
"""Writes the diff fixture pack.

    scripts/make-fixtures.py           # small pairs (Fixtures/pairs) + large ones (Fixtures/generated)
    scripts/make-fixtures.py --huge    # also the 1M-line memory test (~160 MB)

Each pair is a folder holding left.<ext>, right.<ext> and about.txt (what the pair tests,
then what to look for). Output is deterministic, so the small pairs are committed and the
large ones are regenerated on demand. Re-running only rewrites those three files; captures
and notes saved alongside them are left alone.
"""

import random
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "Fixtures"
rng = random.Random(42)
index = []


def pair(folder, number, name, about, look, left, right, ext="txt"):
    d = ROOT / folder / f"{number:02d}-{name}"
    d.mkdir(parents=True, exist_ok=True)
    for old in list(d.glob("left.*")) + list(d.glob("right.*")):
        old.unlink()
    for side, content in (("left", left), ("right", right)):
        data = content.encode("utf-8") if isinstance(content, str) else content
        (d / f"{side}.{ext}").write_bytes(data)
    (d / "about.txt").write_text(f"{about}\nLook for: {look}\n")
    index.append(f"| `{folder}/{d.name}` | {about} |")


def small(*args, **kw):
    pair("pairs", *args, **kw)


def large(*args, **kw):
    pair("generated", *args, **kw)


def lines(text):
    return text.split("\n")


def join(ls):
    return "\n".join(ls)


def insert_after(text, anchor, block):
    assert anchor in text, anchor
    return text.replace(anchor, anchor + block, 1)


def remove(text, block):
    assert block in text, block
    return text.replace(block, "", 1)


README = """\
# Diff fixtures

Pairs of files for checking how Juxta (and other diff tools) handle encodings, line endings,
config-specific alignment and large inputs. Written by `scripts/make-fixtures.py`; edit that
script, not the files. See `docs/testing-plan.md` for how they fit into testing.

- `pairs/`: small, committed. Each folder holds `left.*`, `right.*` and `about.txt` (what it
  tests, then what to look for).
- `generated/`: large timing pairs, not committed. `scripts/make-fixtures.py` recreates them
  (add `--huge` for the 1M-line pair).
- `private/`: your own real configs, never committed. Same layout: `private/<name>/left.cfg`
  and `right.cfg`, plus an optional `about.txt`.

| Pair | Tests |
|---|---|
"""


# MARK: - Base documents

IOS = """\
!
! Last configuration change at 14:02:11 UTC Mon Sep 28 2026 by netops
!
version 17.9
service timestamps debug datetime msec
service timestamps log datetime msec
service password-encryption
!
hostname core-rtr-01
!
boot-start-marker
boot-end-marker
!
vrf definition MGMT
 address-family ipv4
 exit-address-family
!
no aaa new-model
!
ip domain name example.net
ip name-server 10.10.0.53
!
interface Loopback0
 description Router ID
 ip address 10.255.0.1 255.255.255.255
!
interface GigabitEthernet0/0/0
 description Uplink to core-rtr-02
 mtu 9000
 ip address 10.0.12.1 255.255.255.252
 ip ospf network point-to-point
 ip ospf cost 10
 negotiation auto
!
interface GigabitEthernet0/0/1
 description Uplink to core-rtr-03
 mtu 9000
 ip address 10.0.13.1 255.255.255.252
 ip ospf network point-to-point
 ip ospf cost 10
 negotiation auto
!
interface GigabitEthernet0/0/2
 description Customer A
 ip address 192.0.2.1 255.255.255.0
 ip access-group CUST-A-IN in
 negotiation auto
!
interface GigabitEthernet0/0/3
 no ip address
 shutdown
 negotiation auto
!
interface GigabitEthernet0
 vrf forwarding MGMT
 ip address 172.16.0.11 255.255.255.0
 negotiation auto
!
router ospf 1
 router-id 10.255.0.1
 passive-interface default
 no passive-interface GigabitEthernet0/0/0
 no passive-interface GigabitEthernet0/0/1
 network 10.0.0.0 0.0.255.255 area 0
 network 10.255.0.1 0.0.0.0 area 0
!
router bgp 65001
 bgp router-id 10.255.0.1
 bgp log-neighbor-changes
 neighbor 10.255.0.2 remote-as 65001
 neighbor 10.255.0.2 update-source Loopback0
 neighbor 10.255.0.3 remote-as 65001
 neighbor 10.255.0.3 update-source Loopback0
 !
 address-family ipv4
  network 192.0.2.0
  neighbor 10.255.0.2 activate
  neighbor 10.255.0.3 activate
 exit-address-family
!
ip forward-protocol nd
no ip http server
no ip http secure-server
ip route vrf MGMT 0.0.0.0 0.0.0.0 172.16.0.1
!
ip access-list extended CUST-A-IN
 10 permit tcp 192.0.2.0 0.0.0.255 any eq 443
 20 permit tcp 192.0.2.0 0.0.0.255 any eq 80
 30 permit udp 192.0.2.0 0.0.0.255 any eq 53
 40 permit icmp 192.0.2.0 0.0.0.255 any
 50 deny   ip any any log
!
ip prefix-list CUST-A seq 5 permit 192.0.2.0/24
ip prefix-list CUST-A seq 10 permit 198.51.100.0/24
ip prefix-list CUST-A seq 15 deny 0.0.0.0/0 le 32
!
snmp-server community ******** RO
!
banner motd ^C
Authorized access only.
All activity is logged.
^C
!
line con 0
 exec-timeout 15 0
 stopbits 1
line vty 0 4
 exec-timeout 15 0
 transport input ssh
!
ntp server 10.10.0.123
!
end
"""

# A short config for the encoding / line-ending pairs, with some non-ASCII.
SHORT = """\
hostname edge-rtr-07
!
interface GigabitEthernet0/0/0
 description Café Zürich – uplink
 ip address 10.7.0.1 255.255.255.252
!
interface GigabitEthernet0/0/1
 description Müller GmbH
 ip address 203.0.113.1 255.255.255.0
!
end
"""

ACL = """\
 10 permit tcp 192.0.2.0 0.0.0.255 any eq 443
 20 permit tcp 192.0.2.0 0.0.0.255 any eq 80
 30 permit udp 192.0.2.0 0.0.0.255 any eq 53
 40 permit icmp 192.0.2.0 0.0.0.255 any
 50 deny   ip any any log
"""

BGP = IOS[IOS.index("router bgp 65001"):IOS.index("ip forward-protocol nd")]


def switch_config(ports):
    out = ["hostname access-sw-04", "!"]
    for n, body in ports:
        out.append(f"interface GigabitEthernet1/0/{n}")
        out.extend(body)
        out.append("!")
    out.append("end")
    return join(out) + "\n"


UNUSED_PORT = [" switchport access vlan 999", " switchport mode access", " shutdown",
               " spanning-tree portfast"]


def show_interface(name, ip, inp, outp, last_in, errors):
    return f"""\
{name} is up, line protocol is up
  Hardware is ISR4451-X-4x1GE, address is 00a3.d14f.2c{name[-1]}0 (bia 00a3.d14f.2c{name[-1]}0)
  Internet address is {ip}
  MTU 9000 bytes, BW 1000000 Kbit/sec, DLY 10 usec,
     reliability 255/255, txload 1/255, rxload 1/255
  Encapsulation ARPA, loopback not set
  Last input {last_in}, output 00:00:00, output hang never
  Last clearing of "show interface" counters never
  Input queue: 0/375/0/0 (size/max/drops/flushes); Total output drops: 0
  5 minute input rate 41000 bits/sec, 37 packets/sec
  5 minute output rate 39000 bits/sec, 35 packets/sec
     {inp} packets input, {inp * 412} bytes, 0 no buffer
     Received 1214 broadcasts (0 IP multicasts)
     {errors} input errors, 0 CRC, 0 frame, 0 overrun, 0 ignored
     {outp} packets output, {outp * 398} bytes, 0 underruns
     0 output errors, 0 collisions, 1 interface resets
"""


def route(i, age="01:02:03", metric=None):
    m = i % 7 if metric is None else metric
    return (f"O    10.{i // 65536}.{(i // 256) % 256}.{i % 256}/32 [110/{m}] "
            f"via 192.168.1.{i % 250}, {age}, GigabitEthernet0/0/{i % 4}")


def random_age():
    return f"{rng.randrange(24):02d}:{rng.randrange(60):02d}:{rng.randrange(60):02d}"


JUNOS = """\
interfaces {
    ge-0/0/0 {
        description "Uplink to core";
        unit 0 {
            family inet {
                address 10.0.12.2/30;
            }
        }
    }
    ge-0/0/1 {
        vlan-tagging;
        unit 10 {
            vlan-id 10;
            family inet {
                address 192.0.2.1/24;
            }
        }
    }
    lo0 {
        unit 0 {
            family inet {
                address 10.255.0.9/32;
            }
        }
    }
}
"""

C_LEFT = """\
#include <stdio.h>

int add(int a, int b)
{
    return a + b;
}

int sub(int a, int b)
{
    return a - b;
}

int main(void)
{
    printf("%d\\n", add(1, 2));
    return 0;
}
"""

PY_LEFT = """\
import json


def load(path):
    with open(path) as f:
        return json.load(f)


def summarize(records):
    total = sum(r["bytes"] for r in records)
    peak = max(r["bytes"] for r in records)
    return {"total": total, "peak": peak}


def render(summary):
    lines = []
    for key, value in summary.items():
        lines.append(f"{key:>8}: {value}")
    return "\\n".join(lines)


def main():
    records = load("traffic.json")
    print(render(summarize(records)))


if __name__ == "__main__":
    main()
"""

PROSE = ("The maintenance window starts at 02:00 UTC on Saturday. During the window the "
         "core routers will be upgraded one at a time, and traffic will fail over to the "
         "redundant path. Customers on single-homed circuits should expect up to ten minutes "
         "of downtime. If the upgrade fails, we will roll back to the previous image and "
         "reschedule the work for the following weekend.")


def wrap(text, width):
    out, line = [], ""
    for word in text.split():
        if line and len(line) + 1 + len(word) > width:
            out.append(line)
            line = word
        else:
            line = f"{line} {word}" if line else word
    out.append(line)
    return join(out) + "\n"


# MARK: - Encoding, line endings and other "identical but not really" cases (01-21)

def encodings():
    crlf = SHORT.replace("\n", "\r\n")
    small(1, "eol-lf-vs-crlf", "Same text; LF on the left, CRLF on the right.",
          "Says the files differ only in line endings, without marking every line.",
          SHORT, crlf, "cfg")
    small(2, "eol-lf-vs-cr", "Same text; LF on the left, classic Mac CR on the right.",
          "Right side still splits into lines; line-ending difference is called out.",
          SHORT, SHORT.replace("\n", "\r"), "cfg")
    mixed = "".join(l + ("\r\n" if k % 2 else "\n") for k, l in enumerate(lines(SHORT)[:-1]))
    small(3, "eol-mixed-vs-lf", "Left alternates LF and CRLF; right is all LF.",
          "How mixed line endings are reported (per line? a summary?).",
          mixed, SHORT, "cfg")
    small(4, "final-newline-missing", "Right side has no newline at the end of the file.",
          "Whether the missing final newline is shown, and how.",
          SHORT, SHORT.rstrip("\n"), "cfg")
    small(5, "bom-vs-no-bom", "Same text; the right side starts with a UTF-8 BOM.",
          "Whether the BOM is reported or silently ignored.",
          SHORT, b"\xef\xbb\xbf" + SHORT.encode(), "cfg")
    small(6, "utf16le-vs-utf8", "Same text; UTF-16LE with BOM on the left, UTF-8 on the right.",
          "Decodes UTF-16 as text (not binary) and reports the encoding difference.",
          b"\xff\xfe" + SHORT.encode("utf-16-le"), SHORT, "cfg")
    small(7, "utf16be-vs-utf16le", "Same text; UTF-16BE with BOM vs UTF-16LE with BOM.",
          "Treated as identical text, with the byte order noted (or not).",
          b"\xfe\xff" + SHORT.encode("utf-16-be"), b"\xff\xfe" + SHORT.encode("utf-16-le"),
          "cfg")
    small(8, "latin1-vs-utf8", "Same text; ISO-8859-1 on the left, UTF-8 on the right.",
          "Left accents display correctly (encoding guessed) and the encoding is shown.",
          SHORT.replace("–", "-").encode("latin-1"), SHORT.replace("–", "-"), "cfg")
    bad =SHORT.encode().replace("Müller".encode(), b"M\xfc\xffller")
    small(9, "invalid-utf8", "Right side has invalid UTF-8 bytes in one line.",
          "No crash or refusal; how the bad bytes are displayed.",
          SHORT, bad, "cfg")
    filler = join(f"! padding line {i:04d} ------------------------------------------"
                  for i in range(200)) + "\n"
    small(10, "nul-after-8k", "Text file with a NUL byte about 12 KB in (right side only).",
          "Whether a late NUL flips the file to binary; how it is shown.",
          filler, filler[:12000] + "\0" + filler[12001:], "txt")
    png = (b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x10\x00\x00\x00\x10\x08\x06"
           + bytes(rng.randrange(256) for _ in range(400)))
    small(11, "binary-vs-text", "Left is binary (PNG-like bytes), right is text.",
          "Refusal message or hex view; no garbage text.",
          png, SHORT, "bin")
    small(12, "empty-vs-empty", "Two empty files.", "What 'identical' looks like.",
          "", "", "txt")
    small(13, "empty-vs-text", "Empty on the left, text on the right.",
          "Everything shown as added; the empty side's display.", "", SHORT, "cfg")
    small(14, "identical", "Byte-identical files.", "What 'identical' looks like.",
          IOS, IOS, "cfg")
    trailing = join(l + ("  " if k % 3 == 0 and l else "") for k, l in enumerate(lines(IOS)))
    small(15, "trailing-whitespace", "Right side has trailing spaces on every third line.",
          "Whether trailing whitespace is visible; behavior with whitespace ignored.",
          IOS, trailing, "cfg")
    small(16, "tabs-vs-spaces", "Same code; tabs on the left, four spaces on the right.",
          "Display of indentation difference; whitespace-ignore behavior.",
          PY_LEFT.replace("    ", "\t"), PY_LEFT, "py")
    small(17, "case-only", "Right side changes the case of a few keywords.",
          "Inline highlight on the changed letters; ignore-case behavior.",
          IOS, IOS.replace("hostname core-rtr-01", "hostname CORE-RTR-01")
          .replace("description Customer A", "description CUSTOMER A"), "cfg")
    small(18, "blank-lines", "Right side adds blank lines between sections.",
          "Whether there's an option to ignore blank lines.",
          IOS, IOS.replace("\n!\n", "\n!\n\n"), "cfg")
    uni_left = "description Café\nname Zoë\nbanner Hello world\nmatch community 65001:100\n"
    uni_right = (unicodedata.normalize("NFD", "description Café\nname Zoë\n")
                 + "banner Hello world\nmatch community 65001:​100\n")
    small(19, "unicode-invisibles", "NFC vs NFD accents, a non-breaking space, a zero-width space.",
          "Whether these are marked as different and whether the difference is visible.",
          uni_left, uni_right, "txt")
    long_left = " ".join(f"10.{i // 256}.{i % 256}.0/24" for i in range(7000))
    long_right = long_left.replace("10.12.34.0/24", "10.12.35.0/24")
    small(20, "single-long-line", "One ~100 KB line; a single octet changes in the middle.",
          "Responsiveness; whether the change is highlighted and findable.",
          long_left + "\n", long_right + "\n", "txt")
    table = ["Interface              IP-Address      OK? Method Status                Protocol"]
    rows = [("GigabitEthernet0/0/0", "10.0.12.1"), ("GigabitEthernet0/0/1", "10.0.13.1"),
            ("GigabitEthernet0/0/2", "192.0.2.1"), ("GigabitEthernet0/0/3", "unassigned"),
            ("Loopback0", "10.255.0.1")]
    wide = table + [f"{n:<23}{ip:<16}YES NVRAM  up                    up" for n, ip in rows]
    narrow = ["Interface            IP-Address    OK? Method Status    Protocol"] + [
        f"{n:<21}{ip:<14}YES NVRAM  up        up" for n, ip in rows]
    small(21, "column-realignment", "show ip int brief with different column widths.",
          "Lines marked changed; whitespace-ignore makes them identical?",
          join(wide) + "\n", join(narrow) + "\n", "txt")


# MARK: - Show output with timers (22-29)

SHOW_TIMERS = """\
r1#show version | include uptime
r1 uptime is {uptime}
r1#show ip ospf neighbor

Neighbor ID     Pri   State           Dead Time   Address         Interface
10.255.0.2        1   FULL/DR         {dead2}    10.0.12.2       GigabitEthernet0/0/0
10.255.0.3        1   {state3}{dead3}    10.0.13.2       GigabitEthernet0/0/1
r1#show ip bgp summary | begin Neighbor
Neighbor        V           AS MsgRcvd MsgSent   TblVer  InQ OutQ Up/Down  State/PfxRcd
10.255.0.2      4        65001    1204    1187       42    0    0 {up2}           12
10.255.0.3      4        65001     980     975       42    0    0 {up3}
r1#show interfaces | include ^Gi|Last input
GigabitEthernet0/0/0 is up, line protocol is up
  Last input {in0}, output {out0}, output hang never
GigabitEthernet0/0/1 is up, line protocol is up
  Last input {in1}, output {out1}, output hang never
r1#show ipv6 interface brief
GigabitEthernet0/0/0   [up/up]
    FE80::1:22:{v6}
    2001:DB8:12::1
r1#show arp | include 10.0.0.5
Internet  10.0.0.5               14   aabb.1d00.{mac}  ARPA   GigabitEthernet0/0/2
r1#show running-config | include community|periodic
 set community 65000:{community}
 periodic weekdays 08:00 to {until}
"""


def show_timers():
    # No rng here: drawing from it would change every pair generated after these.
    def age(i, later):
        s = 1 if later else 0
        if i % 3 == 0:
            return f"{i % 24:02d}:{(i * 7 + 11 * s) % 60:02d}:{(i * 13 + 29 * s) % 60:02d}"
        if i % 3 == 1:
            return f"{1 + i % 5}w{(i + s) % 7}d"
        return f"{1 + i % 6}d{(i + s) % 24:02d}h"

    left = [route(i, age(i, False)) for i in range(40) if i != 17]
    right = [route(i, "00:00:07" if i == 17 else age(i, True)) for i in range(40)]
    small(22, "route-table-timers", "show ip route before and after adding one route; every age "
          "moved on (hh:mm:ss, 1w2d, 3d04h).",
          "Nearly every line modified; with Ignore Timers only 10.0.0.17/32 (added).",
          join(left) + "\n", join(right) + "\n", "txt")
    before = SHOW_TIMERS.format(
        uptime="2 weeks, 3 days, 4 hours, 5 minutes", dead2="00:00:34", state3="FULL/BDR        ",
        dead3="00:00:38", up2="1w2d", up3="3d04h           7", in0="00:00:01", out0="00:00:00",
        in1="never", out1="00:00:03", v6="33", mac="0100", community="100", until="17:00")
    after = SHOW_TIMERS.format(
        uptime="2 weeks, 3 days, 5 hours, 17 minutes", dead2="00:00:31", state3="INIT/DROTHER    ",
        dead3="00:00:35", up2="1w3d", up3="00:00:12 Idle", in0="00:00:04", out0="00:00:02",
        in1="00:00:02", out1="00:00:01", v6="34", mac="0101", community="200", until="18:00")
    small(23, "show-output-timers", "Show commands captured twice: uptime, neighbor and BGP timers "
          "and Last input moved on, plus six real changes among values that look like timers "
          "(IPv6, MAC, community, time range). Counters held still: Ignore Timers doesn't hide them.",
          "With Ignore Timers, six modified lines: OSPF 10.255.0.3 and BGP 10.255.0.3 state, "
          "FE80::1:22:34, aabb.1d00.0101, 65000:200 and 18:00; no timer highlighted.",
          before, after, "txt")


# MARK: - Config alignment and inline highlighting (30-50)

def configs():
    new_intf = ("interface GigabitEthernet0/0/4\n description Customer B\n"
                " ip address 198.51.100.1 255.255.255.0\n negotiation auto\n!\n")
    small(30, "ios-block-inserted", "New interface block inserted after Gi0/0/3.",
          "Hunk starts at 'interface GigabitEthernet0/0/4' and ends at its '!' "
          "(not shifted by one '!' or 'negotiation auto' line).",
          IOS, insert_after(IOS, " shutdown\n negotiation auto\n!\n", new_intf), "cfg")
    gi2 = ("interface GigabitEthernet0/0/2\n description Customer A\n"
           " ip address 192.0.2.1 255.255.255.0\n ip access-group CUST-A-IN in\n"
           " negotiation auto\n!\n")
    small(31, "ios-block-deleted", "Interface Gi0/0/2 block deleted.",
          "Hunk boundaries line up with the block, not shifted by a shared tail line.",
          IOS, remove(IOS, gi2), "cfg")
    reseq = """\
 10 permit tcp 192.0.2.0 0.0.0.255 any eq 443
 20 permit tcp 192.0.2.0 0.0.0.255 any eq 22
 30 permit tcp 192.0.2.0 0.0.0.255 any eq 80
 40 permit udp 192.0.2.0 0.0.0.255 any eq 53
 50 permit icmp 192.0.2.0 0.0.0.255 any
 60 deny   ip any any log
"""
    small(32, "acl-resequenced", "ACL entry added and the list resequenced (every number shifts).",
          "Pairing of old/new entries and whether only the sequence numbers are highlighted.",
          IOS, IOS.replace(ACL, reseq), "cfg")
    asa = [f"access-list OUTSIDE-IN extended permit tcp any host 203.0.113.{h} eq {p}"
           for h, p in [(10, 443), (10, 80), (11, 25), (12, 53), (13, 22), (14, 3389)]]
    asa_r = [asa[0], asa[3], asa[1], asa[5], asa[2], asa[4]]
    small(33, "acl-reordered", "ASA-style ACL lines reordered, none changed.",
          "Shown as moves, as delete+insert, or as changed pairs?",
          join(asa) + "\n", join(asa_r) + "\n", "cfg")
    small(34, "prefix-list-seq", "Prefix-list entry inserted with a new sequence number.",
          "Clean single-line insert.",
          IOS, insert_after(IOS, "seq 5 permit 192.0.2.0/24\n",
                            "ip prefix-list CUST-A seq 7 permit 192.0.2.128/25\n"), "cfg")
    acl_block = "ip access-list extended CUST-A-IN\n" + ACL + "!\n"
    moved = remove(IOS, acl_block)
    moved = moved.replace("router ospf 1\n", acl_block + "router ospf 1\n", 1)
    small(35, "block-moved", "ACL block moved above 'router ospf', unchanged.",
          "Move detection, or one delete plus one insert (and which side gets anchored).",
          IOS, moved, "cfg")
    small(36, "section-deleted", "Whole 'router bgp' section deleted.",
          "One clean deletion hunk.", IOS, remove(IOS, BGP), "cfg")
    tok = (IOS.replace("ip address 10.0.12.1 ", "ip address 10.0.12.5 ")
           .replace(" mtu 9000\n ip address 10.0.13.1", " mtu 9216\n ip address 10.0.13.1")
           .replace("Uplink to core-rtr-03", "Uplink to core-rtr-13")
           .replace("ip ospf cost 10\n negotiation auto\n!\ninterface GigabitEthernet0/0/2",
                    "ip ospf cost 100\n negotiation auto\n!\ninterface GigabitEthernet0/0/2")
           .replace("interface GigabitEthernet0/0/3", "interface GigabitEthernet0/0/30")
           .replace("172.16.0.1\n", "172.16.0.254\n")
           .replace("line con 0\n exec-timeout 15 0", "line con 0\n exec-timeout 5 0"))
    small(37, "inline-tokens", "Small token edits: IP octets, MTU, interface number, cost, timeout.",
          "Highlights cover whole tokens (10.0.12.1 -> 10.0.12.5, Gi0/0/3 -> Gi0/0/30, "
          "15 -> 5) rather than single characters.",
          IOS, tok, "cfg")
    small(38, "timestamp-header-only", "Only the 'Last configuration change' comment differs.",
          "Single changed line; any option to ignore lines by pattern.",
          IOS, IOS.replace("14:02:11 UTC Mon Sep 28 2026", "09:41:57 UTC Tue Sep 29 2026"),
          "cfg")
    names = [("GigabitEthernet0/0/0", "10.0.12.1/30"), ("GigabitEthernet0/0/1", "10.0.13.1/30"),
             ("GigabitEthernet0/0/2", "192.0.2.1/24"), ("Loopback0", "10.255.0.1/32")]
    before = "".join(show_interface(n, ip, 1_200_000 + k * 7919, 1_100_000 + k * 6007,
                                    "00:00:01", 0) for k, (n, ip) in enumerate(names))
    after = "".join(show_interface(n, ip, 1_203_418 + k * 8123, 1_102_977 + k * 6211,
                                   "00:00:00", 3 if k == 2 else 0) for k, (n, ip) in enumerate(names))
    small(39, "show-interfaces-counters", "show interfaces captured twice; counters moved on.",
          "Paired changed lines with only the numbers highlighted.", before, after, "txt")
    routes_l = [route(i, "01:02:03") for i in range(80)]
    routes_r = [route(i, random_age() if i % 9 == 0 else "01:02:03") for i in range(80)]
    routes_r[40:40] = [f"S    172.16.{k}.0/24 [1/0] via 10.0.0.1" for k in range(3)]
    del routes_r[10]
    small(40, "show-ip-route", "Route table: some ages change, 3 statics added, 1 route gone.",
          "Ages highlighted inline; adds and deletes not paired with unrelated routes.",
          join(routes_l) + "\n", join(routes_r) + "\n", "txt")
    junos_r = insert_after(JUNOS, "                address 192.0.2.1/24;\n            }\n        }\n",
                           "        unit 20 {\n            vlan-id 20;\n            family inet {\n"
                           "                address 198.51.100.1/24;\n            }\n        }\n")
    small(41, "junos-unit-inserted", "Junos: new unit added under ge-0/0/1 (curly braces).",
          "Hunk is exactly the new unit, not shifted by closing braces.",
          JUNOS, junos_r, "conf")
    small(42, "banner-changed", "Multi-line banner text changed.",
          "Pairing of the changed banner lines.",
          IOS, IOS.replace("Authorized access only.\nAll activity is logged.\n",
                           "Authorized access only. Disconnect now if you are not authorized.\n"
                           "All activity is logged and monitored.\nContact noc@example.net.\n"),
          "cfg")
    ports = [(n, list(UNUSED_PORT)) for n in range(1, 25)]
    ports_r = [(n, list(b)) for n, b in ports]
    ports_r[6] = (7, [" description Printer 3F", " switchport access vlan 30",
                      " switchport mode access", " spanning-tree portfast"])
    ports_r[15][1][0] = " switchport access vlan 40"
    small(43, "switch-identical-ports", "24 identical unused ports; two are configured.",
          "Changes land on the right ports (Gi1/0/7 and Gi1/0/16), not a neighbor.",
          switch_config(ports), switch_config(ports_r), "cfg")
    c_right = C_LEFT.replace("int main(void)", "int mul(int a, int b)\n{\n    return a * b;\n}\n\n"
                             "int main(void)")
    small(44, "c-function-inserted", "C: a new function inserted between two others.",
          "Hunk starts at 'int mul', not at the previous closing brace or blank line.",
          C_LEFT, c_right, "c")
    funcs = PY_LEFT.split("\n\n\n")
    py_right = "\n\n\n".join([funcs[0], funcs[3], funcs[2], funcs[1]] + funcs[4:])
    small(45, "python-function-moved", "Python: a function moved to a different position.",
          "Move detection, or a compact delete + insert (not a whole-file rewrite).",
          PY_LEFT, py_right, "py")
    small(46, "prose-rewrapped", "Paragraph rewrapped from 90 to 60 columns.",
          "Whether a reflow-only change is recognized; how noisy it looks.",
          wrap(PROSE, 90), wrap(PROSE, 60), "txt")
    j_left = """{
  "hostname": "core-rtr-01",
  "asn": 65001,
  "loopback": "10.255.0.1",
  "neighbors": ["10.255.0.2", "10.255.0.3"],
  "ntp": "10.10.0.123"
}
"""
    j_right = """{
  "asn": 65001,
  "hostname": "core-rtr-01",
  "neighbors": ["10.255.0.2", "10.255.0.3", "10.255.0.4"],
  "ntp": "10.10.0.123",
  "loopback": "10.255.0.1"
}
"""
    small(47, "json-keys-reordered", "JSON keys reordered plus one real change.",
          "Whether the real change stands out from the reorder noise.", j_left, j_right, "json")
    small(48, "unrelated-small", "Two unrelated files.",
          "What 'completely different' looks like; any degenerate pairing.",
          IOS, PY_LEFT, "txt")
    # Lines that occur several times get no unique anchor (patience can't help).
    dup_l = IOS
    dup_r = IOS.replace(" exec-timeout 15 0\n transport input ssh",
                        " exec-timeout 15 0\n logging synchronous\n transport input ssh")
    small(49, "duplicate-context", "Insert next to a line that appears twice (exec-timeout).",
          "Insert lands under 'line vty', not under 'line con'.", dup_l, dup_r, "cfg")
    big_edit = IOS.replace("interface GigabitEthernet0/0/2\n description Customer A\n"
                           " ip address 192.0.2.1 255.255.255.0\n",
                           "interface GigabitEthernet0/0/2\n description Customer A (migrated)\n"
                           " bandwidth 500000\n ip address 192.0.2.1 255.255.255.128\n"
                           " ip address 192.0.2.129 255.255.255.128 secondary\n")
    small(50, "mixed-edit-in-block", "Block with an edited line, inserted lines and a split line.",
          "Which old line pairs with which new line (description with description, "
          "address with address).", IOS, big_edit, "cfg")


# MARK: - Found by scripts/compare-git.py (51-59)
# Trimmed from public test configs in batfish/batfish (projects/batfish/src/test/resources/
# org/batfish/grammar/*/testconfigs), where Juxta's hunk boundary reads worse than git's.

XR_VRFS = """\
!RANCID-CONTENT-TYPE: cisco-xr
!
hostname xr-vrf-route-target
!

vrf single-oneline
  address-family ipv4 unicast
    export route-target 1:1
    import route-target 2:2
  !
!

vrf multiple
  address-family ipv4 unicast
    export route-target
      5:5
      6:6
    !
  !
!
"""

F5_RULES = """\
#TMSH-VERSION: 13.1.1

sys global-settings {
    hostname f5_bigip_structured_ltm_rule
}

ltm rule /Common/irule_foo {
when HTTP_REQUEST {
    set bar2 [HTTP::header value "bunch-o-stuff"]
    if { $bar2 eq "" } {
        set bar2 [IP::client_addr]
    }

}
}
"""

FORTIOS_INTERFACES = """\
config system global
    set hostname "iface_warn"
end
config system interface
    edit "port1"
        set vdom "root"
        set ip 192.168.122.2 255.255.255.0
        set type physical
    next
    edit "missing_vlanid"
        set vdom root
        set interface port1
    next
    edit "missing_iface"
        set vdom root
        set vlanid 999
    next
end
config system zone
    edit conflict
        set interface port1
    next
end
"""


def git_findings():
    small(51, "xr-vrf-appended", "IOS XR: a blank-separated vrf block appended at the end "
          "(batfish xr-vrf-route-target, commit 784e61cb).",
          "Hunk is the blank line, 'vrf multiple-af' and its closing '!' (as git shows it), "
          "not the previous vrf's '!' through the new vrf's last indented '  !'.",
          XR_VRFS, XR_VRFS + "\nvrf multiple-af\n  address-family ipv4 unicast\n"
          "    export route-target 1:13\n  !\n  address-family ipv6 unicast\n"
          "    export route-target 1:16\n  !\n!\n", "cfg")
    small(52, "f5-rule-appended", "F5 BIG-IP: two blank-separated ltm rules appended at the end "
          "(batfish f5_bigip_structured_ltm_rule, commit 2962380c).",
          "Hunk is the blank line through the last rule's closing '}' (as git shows it), "
          "not the previous rule's '}' through the inner 'when' block's '}'.",
          F5_RULES, F5_RULES + "\nltm rule /Common/empty {\n}\n\nltm rule /Common/empty_when {\n"
          "when HTTP_REQUEST {\n}\n}\n", "txt")
    small(53, "fortios-edit-appended", "FortiOS: an 'edit ... next' entry appended to a config "
          "table (batfish iface_warn, commit 57e8e205).",
          "Hunk runs from 'edit \"secondary\"' to its own 'next' (as git shows it), not from "
          "the previous entry's 'next' to the nested 'end'.",
          FORTIOS_INTERFACES, FORTIOS_INTERFACES.replace(
              "        set vlanid 999\n    next\nend\n",
              "        set vlanid 999\n    next\n    edit \"secondary\"\n        set type physical\n"
              "        set ip 10.0.0.1/24\n        set secondary-IP enable\n        config secondaryip\n"
              "            edit 1\n                set ip 10.0.0.3/24\n            next\n        end\n"
              "    next\nend\n", 1), "cfg")


# MARK: - Large inputs (60-67): timing, responsiveness, memory

def perf(huge):
    def routes_pair(n, every):
        left = [route(i) for i in range(n)]
        right = list(left)
        for i in range(0, n, every):
            right[i] = route(i, random_age())
        return left, right

    left, right = routes_pair(20_000, 20)
    large(60, "routes-20k-5pct", "TIMED. 20k-line route table, 5% of lines changed.",
          "Time until the diff is shown; scrolling smoothness.",
          join(left) + "\n", join(right) + "\n", "txt")
    left, right = routes_pair(200_000, 100)
    del right[5000:5100]
    right[90_000:90_000] = [f"S    172.16.{k}.0/24 [1/0] via 10.0.0.1" for k in range(50)]
    large(61, "routes-200k-1pct", "TIMED. 200k-line route table, 1% changed, a block added and removed.",
          "Time until the diff is shown; scrolling and jumping between changes.",
          join(left) + "\n", join(right) + "\n", "txt")

    def noise(n, seed):
        r = random.Random(seed)
        return join(f"{r.getrandbits(64):016x} {r.getrandbits(64):016x} event={r.randrange(1000)}"
                    for _ in range(n)) + "\n"

    large(62, "unrelated-20k", "TIMED. Two unrelated 20k-line files.",
          "Time to give up; whether it hangs or shows progress.", noise(20_000, 1), noise(20_000, 2))
    large(63, "unrelated-100k", "TIMED. Two unrelated 100k-line files.",
          "Time to give up; whether it hangs, shows progress or offers cancel.",
          noise(100_000, 3), noise(100_000, 4))
    vocab = ["!", " negotiation auto", " shutdown", " no shutdown", " switchport mode access",
             " spanning-tree portfast", " switchport access vlan 10", " switchport access vlan 20",
             " exit", " no ip address", " description unused", " mtu 9000", "", " speed auto",
             " duplex auto", " cdp enable", " lldp transmit", " lldp receive", " storm-control on",
             " power inline auto"]
    left = [rng.choice(vocab) for _ in range(100_000)]
    right = [rng.choice(vocab) if rng.random() < 0.02 else l for l in left]
    large(64, "low-unique-100k", "TIMED. 100k lines from a 20-line vocabulary; 2% changed.",
          "Time to show (no unique lines to anchor on); readable result?",
          join(left) + "\n", join(right) + "\n", "cfg")
    left = [route(i) for i in range(20_000)]
    right = list(left)
    block = [route(i, random_age(), metric=(i % 7) + 1) for i in range(5000, 6000)]
    for k in sorted(rng.sample(range(1000), 30), reverse=True):
        block.insert(k, f"S    172.17.{k % 256}.0/24 [1/0] via 10.0.0.2")
    right[5000:6000] = block
    large(65, "big-changed-block", "TIMED. 1000-line block where every line changed and 30 lines "
          "were inserted inside it.",
          "Old and new lines stay paired after the insertions (no drift).",
          join(left) + "\n", join(right) + "\n", "txt")
    left = [route(i) for i in range(50_000)]
    right = [route(i, random_age()) for i in range(50_000)]
    large(66, "every-line-changed-50k", "TIMED. 50k lines, every line's age changed.",
          "Time to show; inline highlights while scrolling quickly.",
          join(left) + "\n", join(right) + "\n", "txt")
    if huge:
        left, right = routes_pair(1_000_000, 1000)
        large(67, "routes-1m", "TIMED. 1M-line route table (~78 MB per side), 0.1% changed.",
              "Time to show; memory use in Activity Monitor; scrolling.",
              join(left) + "\n", join(right) + "\n", "txt")


if __name__ == "__main__":
    encodings()
    show_timers()
    configs()
    git_findings()
    perf("--huge" in sys.argv)
    (ROOT / "README.md").write_text(README + "\n".join(index) + "\n")
    print(f"Wrote fixtures under {ROOT}")
