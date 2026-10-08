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
| `pairs/01-eol-lf-vs-crlf` | Same text; LF on the left, CRLF on the right. |
| `pairs/02-eol-lf-vs-cr` | Same text; LF on the left, classic Mac CR on the right. |
| `pairs/03-eol-mixed-vs-lf` | Left alternates LF and CRLF; right is all LF. |
| `pairs/04-final-newline-missing` | Right side has no newline at the end of the file. |
| `pairs/05-bom-vs-no-bom` | Same text; the right side starts with a UTF-8 BOM. |
| `pairs/06-utf16le-vs-utf8` | Same text; UTF-16LE with BOM on the left, UTF-8 on the right. |
| `pairs/07-utf16be-vs-utf16le` | Same text; UTF-16BE with BOM vs UTF-16LE with BOM. |
| `pairs/08-latin1-vs-utf8` | Same text; ISO-8859-1 on the left, UTF-8 on the right. |
| `pairs/09-invalid-utf8` | Right side has invalid UTF-8 bytes in one line. |
| `pairs/10-nul-after-8k` | Text file with a NUL byte about 12 KB in (right side only). |
| `pairs/11-binary-vs-text` | Left is binary (PNG-like bytes), right is text. |
| `pairs/12-empty-vs-empty` | Two empty files. |
| `pairs/13-empty-vs-text` | Empty on the left, text on the right. |
| `pairs/14-identical` | Byte-identical files. |
| `pairs/15-trailing-whitespace` | Right side has trailing spaces on every third line. |
| `pairs/16-tabs-vs-spaces` | Same code; tabs on the left, four spaces on the right. |
| `pairs/17-case-only` | Right side changes the case of a few keywords. |
| `pairs/18-blank-lines` | Right side adds blank lines between sections. |
| `pairs/19-unicode-invisibles` | NFC vs NFD accents, a non-breaking space, a zero-width space. |
| `pairs/20-single-long-line` | One ~100 KB line; a single octet changes in the middle. |
| `pairs/21-column-realignment` | show ip int brief with different column widths. |
| `pairs/22-route-table-timers` | show ip route before and after adding one route; every age moved on (hh:mm:ss, 1w2d, 3d04h). |
| `pairs/23-show-output-timers` | Show commands captured twice: uptime, neighbor and BGP timers and Last input moved on, plus six real changes among values that look like timers (IPv6, MAC, community, time range). Counters held still: Ignore Timers doesn't hide them. |
| `pairs/30-ios-block-inserted` | New interface block inserted after Gi0/0/3. |
| `pairs/31-ios-block-deleted` | Interface Gi0/0/2 block deleted. |
| `pairs/32-acl-resequenced` | ACL entry added and the list resequenced (every number shifts). |
| `pairs/33-acl-reordered` | ASA-style ACL lines reordered, none changed. |
| `pairs/34-prefix-list-seq` | Prefix-list entry inserted with a new sequence number. |
| `pairs/35-block-moved` | ACL block moved above 'router ospf', unchanged. |
| `pairs/36-section-deleted` | Whole 'router bgp' section deleted. |
| `pairs/37-inline-tokens` | Small token edits: IP octets, MTU, interface number, cost, timeout. |
| `pairs/38-timestamp-header-only` | Only the 'Last configuration change' comment differs. |
| `pairs/39-show-interfaces-counters` | show interfaces captured twice; counters moved on. |
| `pairs/40-show-ip-route` | Route table: some ages change, 3 statics added, 1 route gone. |
| `pairs/41-junos-unit-inserted` | Junos: new unit added under ge-0/0/1 (curly braces). |
| `pairs/42-banner-changed` | Multi-line banner text changed. |
| `pairs/43-switch-identical-ports` | 24 identical unused ports; two are configured. |
| `pairs/44-c-function-inserted` | C: a new function inserted between two others. |
| `pairs/45-python-function-moved` | Python: a function moved to a different position. |
| `pairs/46-prose-rewrapped` | Paragraph rewrapped from 90 to 60 columns. |
| `pairs/47-json-keys-reordered` | JSON keys reordered plus one real change. |
| `pairs/48-unrelated-small` | Two unrelated files. |
| `pairs/49-duplicate-context` | Insert next to a line that appears twice (exec-timeout). |
| `pairs/50-mixed-edit-in-block` | Block with an edited line, inserted lines and a split line. |
| `pairs/51-xr-vrf-appended` | IOS XR: a blank-separated vrf block appended at the end (batfish xr-vrf-route-target, commit 784e61cb). |
| `pairs/52-f5-rule-appended` | F5 BIG-IP: two blank-separated ltm rules appended at the end (batfish f5_bigip_structured_ltm_rule, commit 2962380c). |
| `pairs/53-fortios-edit-appended` | FortiOS: an 'edit ... next' entry appended to a config table (batfish iface_warn, commit 57e8e205). |
| `generated/60-routes-20k-5pct` | TIMED. 20k-line route table, 5% of lines changed. |
| `generated/61-routes-200k-1pct` | TIMED. 200k-line route table, 1% changed, a block added and removed. |
| `generated/62-unrelated-20k` | TIMED. Two unrelated 20k-line files. |
| `generated/63-unrelated-100k` | TIMED. Two unrelated 100k-line files. |
| `generated/64-low-unique-100k` | TIMED. 100k lines from a 20-line vocabulary; 2% changed. |
| `generated/65-big-changed-block` | TIMED. 1000-line block where every line changed and 30 lines were inserted inside it. |
| `generated/66-every-line-changed-50k` | TIMED. 50k lines, every line's age changed. |
| `generated/67-routes-1m` | TIMED. 1M-line route table (~78 MB per side), 0.1% changed. |
