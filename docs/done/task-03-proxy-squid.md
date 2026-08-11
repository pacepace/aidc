# task-03: Proxy — Squid

## Objective

Build the Squid forward proxy container that the dev container routes all HTTP/HTTPS through. Configure it for HTTP CONNECT-level domain blocking with two ACLs: one fed from a refresher-managed malware blocklist, one from a hand-maintained state-actor TLD policy. Default policy is permit; only named threats are denied.

---

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| NET-01 | All HTTP/HTTPS egress traverses the proxy stack | P0 |
| NET-02 | Filtering model is blocklist (default permit) | P0 |
| NET-04 | Squid consults a file-backed blocklist | P0 |
| NET-05 | State-actor TLD policy file blocks default `.ru .cn .by .ir .kp` | P0 |
| NET-10 | Proxy lives outside dev container | P0 |
| NET-11 | Previous blocklist serves if refresher fails | P0 |

---

## Design Context

From `docs/design-04-proxy-stack.md`:
> Squid is the HTTP/HTTPS forward proxy through which all dev-container egress flows. Listen on port `3128`. `dns_nameservers 9.9.9.9 149.112.112.112`. ACL: `acl bad_tld dstdomain` reading from `/etc/squid/state-actor-tlds.txt`. ACL: `acl malware_domains dstdomain` reading from `/etc/squid/blocklist.txt` (refresher-managed). `http_access deny malware_domains`. `http_access deny bad_tld`. `http_access allow all`. `access_log /var/log/squid/access.log squid`.

> By default, Squid only sees the **CONNECT host:port** for HTTPS — it cannot inspect URLs, headers, or bodies. That's enough for our needs: we block by domain. We deliberately do **not** enable SSL bumping.

---

## Files to Create

### `proxy/squid/Dockerfile`

Base on the official Squid Docker image (`ubuntu/squid:latest` from Canonical or `sameersbn/squid:latest`). Prefer the Canonical-maintained `ubuntu/squid` image for a known-good upstream.

- Pin by digest where practical (note: Canonical's image isn't always digest-stable; use `ubuntu/squid:6.10-24.04_stable` or similar specific tag if digest pinning is impractical).
- COPY `squid.conf` to `/etc/squid/squid.conf`
- COPY `state-actor-tlds.txt` to `/etc/squid/state-actor-tlds.txt`
- COPY an empty `blocklist.txt` to `/etc/squid/blocklist.txt` (so Squid can start before the refresher writes anything — NET-11)
- Create `/var/log/squid/` with appropriate ownership
- Expose port 3128
- Default Squid entrypoint is preserved

### `proxy/squid/squid.conf`

```
# aidc Squid configuration
# Domain-level blocklist forward proxy.

# Listen on standard squid port
http_port 3128

# DNS — use Quad9 directly (does not go through ourselves)
dns_nameservers 9.9.9.9 149.112.112.112

# ACL definitions
acl localnet src 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8

# Standard ports allow-list (denies CONNECT to e.g. SMTP)
acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 443
acl Safe_ports port 21
acl Safe_ports port 1025-65535
acl CONNECT method CONNECT

# aidc policy ACLs
acl malware_domains dstdomain "/etc/squid/blocklist.txt"
acl bad_tld dstdomain "/etc/squid/state-actor-tlds.txt"

# Access policy (order matters — first match wins)
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access deny malware_domains
http_access deny bad_tld
http_access allow localnet
http_access deny all

# Logging — use squid native format; the policy sidecar parses this
access_log /var/log/squid/access.log squid

# Disable cache (we don't need it for a dev sandbox)
cache deny all

# Reasonable defaults
forwarded_for delete
via off
httpd_suppress_version_string on

# Be reachable from the docker network without name resolution issues
visible_hostname aidc-proxy

# Reload signal handling — refresher sends SIGHUP via shared PID namespace
shutdown_lifetime 5 seconds
```

### `proxy/squid/state-actor-tlds.txt`

```
# aidc default state-actor TLD policy
# One pattern per line. Squid's dstdomain matches by suffix.
# Lines starting with # are comments.
.ru
.cn
.by
.ir
.kp
```

### `proxy/squid/blocklist.txt`

Create empty file with a single comment line so Squid doesn't choke on a zero-byte ACL file:

```
# aidc malware blocklist — populated by the refresher sidecar (proxy/refresher/).
# This file exists empty in the image so Squid can start before first refresh.
```

### `proxy/squid/healthcheck.sh`

```bash
#!/usr/bin/env bash
# Squid healthcheck: verify the proxy answers on port 3128.
# Used by docker-compose healthcheck.
set -euo pipefail
exec 3<>/dev/tcp/127.0.0.1/3128
echo -e "GET / HTTP/1.0\r\n\r\n" >&3
read -r line <&3
case "$line" in
    HTTP/* ) exit 0 ;;
    * ) exit 1 ;;
esac
```

Copied into the image at `/usr/local/bin/healthcheck.sh` (chmod +x).

---

## Implementation Notes

1. **Base image choice.** Canonical's `ubuntu/squid` is well-maintained and tracks Squid 6.x stable. Use the `6.10-24.04_stable` tag (or whatever the current stable point release is at implementation time). Document in a comment why this tag.

2. **HTTPS handling.** No SSL bumping. We rely on the CONNECT verb's host argument being inspectable by ACLs. This is a deliberate constraint documented in `design-04-proxy-stack.md`.

3. **localnet ACL.** Includes the Docker bridge ranges so dev containers can reach Squid. We don't bind 3128 to the host — the proxy is only reachable from inside the per-session Docker network (compose enforces this).

4. **File mounts at runtime.** The compose template (task-07) mounts the named volume `aidc-<session>-blocklist` over `/etc/squid/blocklist.txt`'s directory so the refresher can write and Squid can re-read. Keep this in mind — the in-image blocklist.txt is the fallback, the runtime file is what's read after first mount.

5. **Squid reload semantics.** `squid -k reconfigure` re-reads ACL files without disrupting in-flight connections. The refresher sends SIGHUP via shared PID namespace; Squid's default signal handling treats SIGHUP as reconfigure. Confirm this in the docs / by experimentation.

6. **Logging format.** Use `squid` format (the default verbose format) for `access.log`. The policy sidecar (task-05) parses this; if you change the format here, change the parser there.

---

## Anti-patterns

- DO NOT enable SSL bumping (`ssl_bump` directives). Adds CA-management surface and decryption complexity we don't want.
- DO NOT bind port 3128 to the host (`ports:` in compose). The proxy serves only the inner stack.
- DO NOT enable caching (`cache_dir` or `cache allow`). Not needed for a sandbox proxy.
- AVOID `http_access allow all` at the top. Order matters — denies must come first.

---

## Success Criteria

- [ ] `proxy/squid/Dockerfile` builds successfully: `docker build -t aidc-squid-test proxy/squid/`
- [ ] Container starts and listens on 3128: `docker run --rm -d --name sq-test -p 3128:3128 aidc-squid-test && curl -x localhost:3128 http://example.com -o /dev/null -w "%{http_code}"` returns `200`
- [ ] A blocked TLD is denied: `curl -x localhost:3128 -s -o /dev/null -w "%{http_code}" http://test.cn` returns `403`
- [ ] The blocklist ACL reads from `/etc/squid/blocklist.txt`: `docker exec sq-test grep blocklist.txt /etc/squid/squid.conf`
- [ ] Access log writes to `/var/log/squid/access.log`: `docker exec sq-test ls /var/log/squid/access.log`

---

## Verification

```bash
# Build
docker build -t aidc-squid-test proxy/squid/

# Start with port mapped for local testing
docker run --rm -d --name sq-test -p 13128:3128 aidc-squid-test

# Sleep briefly for startup
sleep 3

# Healthcheck succeeds
docker exec sq-test /usr/local/bin/healthcheck.sh && echo "healthcheck OK"

# Allow check (should 200)
curl -s -x localhost:13128 -o /dev/null -w "allow=%{http_code}\n" http://example.com

# Block check — bad TLD (should 403)
curl -s -x localhost:13128 -o /dev/null -w "tld_block=%{http_code}\n" http://anything.cn

# Add a domain to the blocklist live and reconfigure
docker exec sq-test bash -c 'echo "blocked.example" >> /etc/squid/blocklist.txt && squid -k reconfigure'
sleep 1
curl -s -x localhost:13128 -o /dev/null -w "malware_block=%{http_code}\n" http://blocked.example

# Cleanup
docker rm -f sq-test
```

Expected output:
```
allow=200
tld_block=403
malware_block=403
```

---

## Enforcement Test Suggestions

- [ ] SSL bumping must never be enabled — suggested test: grep squid.conf for `ssl_bump` or `http_port .* ssl-bump`
- [ ] localnet ACL must include private ranges — suggested test: grep squid.conf for `acl localnet src 10\.`
- [ ] http_access ordering: denies before allows — suggested test: parse squid.conf, verify deny rules precede `http_access allow all`-equivalents
