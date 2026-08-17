#!/usr/bin/env bash
# Assertion suite for `grove unpublish` / `grove unpublish-zone`.
#
#     tests/unpublish.sh            # this checkout
#     tests/unpublish.sh /some/grove
#
# WHY IT IS SHAPED LIKE THIS. Every claim about routing is proven by asking which upstream ANSWERED,
# never by reading the file grove generated — the bug this whole area keeps producing is a config
# that looks right and serves the wrong project, which no amount of reading the file catches.
#
# So it stands up a SECOND Caddy (admin :2020, https :8443, its own scratch zone) with three real TLS
# upstreams, and drives the actual binary against it. It needs no root, no DNS and no certificate
# authority, and it never touches the machine's real proxy on :2019 — which it checks at the end,
# because "the tests passed and took the machine down" is the one outcome worth ruling out.
set -uo pipefail

W="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
G="$W/bin/grove"
[ -x "$G" ] || { echo "no grove binary at $G"; exit 1; }
for t in caddy python3 openssl curl; do
	command -v "$t" >/dev/null 2>&1 || { echo "missing: $t"; exit 1; }
done
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.scratch"
ZONE=scratch.example.test
STORE="$HOME/.local/share/grove/$ZONE"
REG="$STORE/projects.tsv"
SITES="$S/sites"
ZF="$SITES/$ZONE.caddy"
# The same interface walk bin/grove uses. Assuming en0 breaks every routing assertion the moment the
# machine is on a dock — and breaks it for a reason that has nothing to do with the code under test.
lan_ip() {
	local i ip
	for i in $(ifconfig -l 2>/dev/null); do
		case "$i" in lo*|awdl*|llw*|utun*|bridge*|gif*|stf*) continue ;; esac
		ip="$(ipconfig getifaddr "$i" 2>/dev/null)"
		[ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
	done
	return 1
}
IP="$(lan_ip)" || { echo "no LAN address — cannot run"; exit 1; }
# Snapshot whatever this machine is really serving, so the last section can prove the suite left it
# alone. Both are captured rather than hardcoded: the machine running this has its own projects.
# Hash the RESPONSE, not the pipeline: `md5` of no input still prints a hash (the empty string's),
# so piping curl straight into it can never produce the empty value the skip below tests for — and a
# machine with no proxy would then compare d41d8cd… to d41d8cd… and call it a pass.
live_config() { curl -s --max-time 3 localhost:2019/config/ 2>/dev/null; }
live_hash() { local c; c="$(live_config)"; [ -n "$c" ] && printf '%s' "$c" | md5; }
LIVE_BASELINE="$(live_hash)"
LIVE_SITES="$(ls "$HOME/.config/grove/sites/" 2>/dev/null)"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
is()   { [ "$2" = "$3" ] && ok "$1" || no "$1" "$2" "$3"; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) no "$1" "output containing: $2" "$3" ;; esac; }
hasnt(){ case "$3" in *"$2"*) no "$1" "output WITHOUT: $2" "$3" ;; *) ok "$1" ;; esac; }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; }
head2() { printf '\n\033[1m%s\033[0m\n' "$1"; }

g() { local p="$1"; shift; GROVE_PROJECT_ROOT="$S/proj-$p" "$G" "$@" 2>&1; }
# Which upstream answers a hostname (empty = nothing serves it).
who() { curl -sk --max-time 5 --resolve "$1:8443:$IP" "https://$1:8443/" 2>/dev/null | sed 's/UPSTREAM=\([^ ]*\).*/\1/'; }

# --- fixture ------------------------------------------------------------------------------------
pkill -f "caddy run --config $S/caddy/Caddyfile" 2>/dev/null; pkill -f "$S/upstream.py" 2>/dev/null
rm -rf "$S" "$STORE"; mkdir -p "$S/caddy" "$SITES" "$STORE/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
	-keyout "$STORE/certs/_.$ZONE.key" -out "$STORE/certs/_.$ZONE.crt" \
	-subj "/CN=*.$ZONE" -addext "subjectAltName=DNS:*.$ZONE,DNS:$ZONE" >/dev/null 2>&1
chmod 644 "$STORE/certs"/*.crt; chmod 640 "$STORE/certs"/*.key
mkdir -p "$STORE/lego/accounts"; echo '{"fake":"acme account"}' > "$STORE/lego/accounts/acct.json"

cat > "$S/caddy/Caddyfile" <<EOF
{
	admin localhost:2020
	http_port 8080
	https_port 8443
}
import $SITES/*.caddy
EOF

for p in a b c; do
	case $p in a) port=39001 ;; b) port=39002 ;; c) port=39003 ;; esac
	mkdir -p "$S/proj-$p"
	cat > "$S/proj-$p/.grove.conf" <<EOF
GROVE_PROJECT="scratch-$p"
GROVE_ZONE="$ZONE"
GROVE_UPSTREAM_PORT="$port"
GROVE_ACME_EMAIL="test@example.test"
GROVE_CADDYFILE="$S/caddy/Caddyfile"
GROVE_SITES_DIR="$SITES"
GROVE_CADDY_ADMIN="localhost:2020"
GROVE_SLOTS=2
GROVE_STACK="none"
EOF
done

cat > "$S/upstream.py" <<'EOF'
import http.server, ssl, sys
port, name, crt, key = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = ("UPSTREAM=%s HOST=%s" % (name, self.headers.get('Host'))).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(crt, key)
srv = http.server.HTTPServer(('127.0.0.1', port), H)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True); srv.serve_forever()
EOF
for p in a:39001 b:39002 c:39003; do
	nohup python3 "$S/upstream.py" "${p##*:}" "scratch-${p%%:*}" \
		"$STORE/certs/_.$ZONE.crt" "$STORE/certs/_.$ZONE.key" >/dev/null 2>&1 &
done
nohup caddy run --config "$S/caddy/Caddyfile" --adapter caddyfile > "$S/caddy/run.log" 2>&1 &
sleep 3

publish_all() { for p in "$@"; do g "$p" publish >/dev/null; done; }
reset_zone() {
	rm -f "$SITES"/*.caddy; rm -f "$REG"
	caddy reload --config "$S/caddy/Caddyfile" --adapter caddyfile >/dev/null 2>&1
}

# --- 1. baseline ---------------------------------------------------------------------------------
head2 "1. publish a, b, c — a owns the default upstream"
publish_all a b c
has "the block binds the address the probes will use" "bind $IP" "$(cat "$ZF")"
is "a's names reach a"          scratch-a "$(who wt1-scratch-a.$ZONE)"
is "b's names reach b"          scratch-b "$(who wt1-scratch-b.$ZONE)"
is "c's names reach c"          scratch-c "$(who wt1-scratch-c.$ZONE)"
is "unclaimed names reach the default (a)" scratch-a "$(who unclaimed.$ZONE)"

# --- 2. remove a matcher -------------------------------------------------------------------------
head2 "2. unpublish c — a plain matcher"
out="$(g c unpublish)"
is "c's names now fall to the default" scratch-a "$(who wt1-scratch-c.$ZONE)"
is "b is untouched"                    scratch-b "$(who wt1-scratch-b.$ZONE)"
hasnt "c's matcher is gone from the zone file" "scratch-c" "$(cat "$ZF")"
is "c's registry row is gone"          "0" "$(grep -c '^scratch-c	' "$REG")"
has "it says the names are unclaimed now" "answer with scratch-a's site" "$out"
has "status no longer routes c" "does NOT route scratch-c" "$(g c status)"

# --- 3. promotion, with another matcher present (the ordering case) -------------------------------
head2 "3. unpublish a — the DEFAULT, with b and c both present"
reset_zone; publish_all a b c
out="$(g a unpublish --promote scratch-c)"
has "it promotes the named project"  "promoted scratch-c" "$out"
is "b keeps its matcher — the promoted default did NOT swallow it" scratch-b "$(who wt1-scratch-b.$ZONE)"
is "unclaimed names reach the promoted default" scratch-c "$(who unclaimed.$ZONE)"
is "a's names fall to the promoted default"     scratch-c "$(who wt1-scratch-a.$ZONE)"
has "the block header credits the promoted project" "added by grove for scratch-c" "$(cat "$ZF")"
hasnt "the promoted block carries no 'added by grove' tag (publish would strip it)" \
	"# scratch-c — added by grove" "$(cat "$ZF")"

# --- 4. auto-pick ---------------------------------------------------------------------------------
head2 "4. unpublish the default with no --promote"
reset_zone; publish_all a b c
out="$(g a unpublish)"
has "it picks the first candidate and says so"   "promoted scratch-b" "$out"
has "it names the flag for choosing differently" "--promote <project>" "$out"
is "the auto-promoted project serves unclaimed names" scratch-b "$(who unclaimed.$ZONE)"

# --- 5. nothing to promote ------------------------------------------------------------------------
head2 "5. unpublish the default when nothing can be promoted"
reset_zone; publish_all a
printf 'scratch-d\t39004\t*-scratch-d.%s\n' "$ZONE" >> "$REG"
before="$(cat "$ZF")"
out="$(g a unpublish)"
has "it refuses with a reason" "no other project on it has a matcher to promote" "$out"
is  "the zone file is untouched" "$before" "$(cat "$ZF")"
is  "a still serves"             scratch-a "$(who wt1-scratch-a.$ZONE)"

# --- 6. the last project --------------------------------------------------------------------------
head2 "6. unpublish the last project"
reset_zone; publish_all a
out="$(g a unpublish)"
is "the site file is gone"      "0" "$(ls -A "$SITES" | wc -l | tr -d ' ')"
is "the registry is empty"      "0" "$(wc -c < "$REG" | tr -d ' ')"
is "nothing answers on the zone" "" "$(who wt1-scratch-a.$ZONE)"
has "it points at the zone teardown" "grove unpublish-zone" "$out"
hasnt "it does NOT ask for sudo (no timer installed)" "sudo" "$out"

# --- 7. drift between registry and config ---------------------------------------------------------
head2 "7. registry/config drift, both directions"
reset_zone; publish_all a b
printf 'scratch-d\t39004\t*-scratch-d.%s\n' "$ZONE" >> "$REG"; sort -o "$REG" "$REG"
mkdir -p "$S/proj-d"; sed 's/scratch-b/scratch-d/; s/39002/39004/' "$S/proj-b/.grove.conf" > "$S/proj-d/.grove.conf"
out="$(g d unpublish)"
has "a row with no matcher: says so"      "does not route scratch-d" "$out"
is  "…and the row is still removed"       "0" "$(grep -c '^scratch-d	' "$REG")"
grep -v '^scratch-b	' "$REG" > "$REG.t" && mv "$REG.t" "$REG"
out="$(g b unpublish)"
has "a matcher with no row: matcher removed" "removed the scratch-b matcher" "$out"
is  "…and b stops being served"           scratch-a "$(who wt1-scratch-b.$ZONE)"

# --- 8. legacy per-project filename (the live dev.rovexo.com shape) --------------------------------
head2 "8. the zone block in a file named after a PROJECT, no header comment"
reset_zone; publish_all a
grep -v '^#' "$ZF" > "$SITES/proj-a.caddy"; rm "$ZF"
out="$(g a unpublish)"
has "found by content, not by name" "proj-a.caddy" "$out"
is  "the legacy file is removed"    "0" "$(ls -A "$SITES" | wc -l | tr -d ' ')"

# --- 9. a brace-less default ----------------------------------------------------------------------
head2 "9. a default reverse_proxy written as a one-liner"
reset_zone; publish_all a b
python3 - "$ZF" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
s = re.sub(r'\treverse_proxy https://127\.0\.0\.1:39001 \{.*?\n\t\}\n', '\treverse_proxy https://127.0.0.1:39001\n', s, flags=re.S)
open(p, 'w').write(s)
PY
caddy reload --config "$S/caddy/Caddyfile" --adapter caddyfile >/dev/null 2>&1
out="$(g a unpublish)"
has "b is still promoted"                "promoted scratch-b" "$out"
is  "the block survived intact"          scratch-b "$(who unclaimed.$ZONE)"
is  "…and still parses as one block"     "1" "$(grep -c 'reverse_proxy' "$ZF")"

# --- 10. round trip -------------------------------------------------------------------------------
head2 "10. publish → unpublish → publish"
reset_zone; publish_all a b       # a owns the default, b is a matcher
g a unpublish >/dev/null          # …a leaves, so b is promoted INTO the default
publish_all a                     # …and a rejoins, now as a matcher
is "a serves again"                 scratch-a "$(who wt1-scratch-a.$ZONE)"
is "b still serves"                 scratch-b "$(who wt1-scratch-b.$ZONE)"
is "the promoted project needs no matcher" "0" "$(grep -c '# scratch-b — added by grove' "$ZF")"
publish_all a                     # publishing twice must not duplicate the block
is "publish stays idempotent"       "1" "$(grep -c '# scratch-a — added by grove' "$ZF")"
is "…and a still serves after it"   scratch-a "$(who wt1-scratch-a.$ZONE)"

# --- 11. zone teardown, unprivileged --------------------------------------------------------------
head2 "11. grove unpublish-zone as an ordinary user"
reset_zone
out="$(g a unpublish-zone)"
is  "the certificate store is gone"  "0" "$([ -d "$STORE" ] && echo 1 || echo 0)"
has "…and it says no root was needed" "no root needed" "$out"
hasnt "it does not ask for sudo"      "sudo" "$out"

# --- 12. teardown that cannot finish --------------------------------------------------------------
head2 "12. a certificate store with a subdirectory the user cannot empty"
mkdir -p "$STORE/certs" "$STORE/lego/inner"; echo x > "$STORE/lego/inner/f"; chmod 500 "$STORE/lego/inner"
out="$(g a unpublish-zone)"
has "it reports the failure instead of claiming success" "could not remove all of" "$out"
has "…and names the fix"                                 "sudo rm -rf"             "$out"
is  "the store is still there"                           "1" "$([ -d "$STORE" ] && echo 1 || echo 0)"
chmod 700 "$STORE/lego/inner"; rm -rf "$STORE"

# --- 13. interlocks -------------------------------------------------------------------------------
head2 "13. the teardown interlocks"
mkdir -p "$STORE/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -keyout "$STORE/certs/_.$ZONE.key" \
	-out "$STORE/certs/_.$ZONE.crt" -subj "/CN=*.$ZONE" >/dev/null 2>&1
publish_all a
has "refuses while the proxy still serves the zone" "the proxy still serves" "$(g a unpublish-zone)"
is  "…and the store survives"                       "1" "$([ -d "$STORE" ] && echo 1 || echo 0)"
g a unpublish >/dev/null
printf 'ghost\t39099\t*-ghost.%s\n' "$ZONE" > "$REG"
has "refuses while the registry lists projects" "still lists: ghost" "$(g a unpublish-zone)"
has "a mistyped flag is refused, not ignored"   "unknown option: --forse" "$(g a unpublish-zone --forse)"
out="$(g a unpublish-zone --force)"
is  "--force proceeds"                          "0" "$([ -d "$STORE" ] && echo 1 || echo 0)"

# --- 14. a zone that HAS a renewal timer ----------------------------------------------------------
# The one path that cannot be finished without root. GROVE_DAEMON_PLIST points the daemon somewhere
# writable so the branch runs as an ordinary user; nothing else about it changes.
head2 "14. a zone with a renewal timer installed — the one part that needs root"
FAKE_PLIST="$S/fake-daemon.plist"
printf '<plist version="1.0"><dict/></plist>\n' > "$FAKE_PLIST"
echo "GROVE_DAEMON_PLIST=\"$FAKE_PLIST\"" >> "$S/proj-a/.grove.conf"
mkdir -p "$STORE/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -keyout "$STORE/certs/_.$ZONE.key" \
	-out "$STORE/certs/_.$ZONE.crt" -subj "/CN=*.$ZONE" >/dev/null 2>&1
echo "renewal script" > "$STORE/renew.sh"
publish_all a
out="$(g a unpublish)"
has "the last-project message lists the timer"   "the renewal timer com.rovexo.grove.renew" "$out"
has "…and says the certificate store needs none" "needs no root for the certificate store" "$out"
out="$(g a unpublish-zone)"
is  "the store is removed anyway"                "0" "$([ -d "$STORE" ] && echo 1 || echo 0)"
has "…and it says so without root"               "no root needed" "$out"
has "it warns the timer is still installed"      "the renewal timer is still installed" "$out"
has "…names the one privileged command"          "sudo grove unpublish-zone" "$out"
hasnt "…and does NOT claim the zone is gone"     "is gone from this machine" "$out"
is  "the plist is untouched by the unprivileged run" "1" "$([ -f "$FAKE_PLIST" ] && echo 1 || echo 0)"
rm -f "$FAKE_PLIST"
out="$(g a unpublish-zone)"
has "with the timer gone, it completes"          "is gone from this machine" "$out"
hasnt "…and stops mentioning sudo"               "sudo" "$out"

# --- 15. the machine's real proxy -----------------------------------------------------------------
head2 "15. the machine's own proxy was never touched"
# Skipped rather than silently passed when there is nothing on :2019 — comparing one empty string to
# another is a green tick for a check that did not happen, which is worse than no check at all.
if [ -n "$LIVE_BASELINE" ]; then
	is "its running config is byte-identical" "$LIVE_BASELINE" "$(live_hash)"
	is "its site files are untouched"         "$LIVE_SITES"    "$(ls "$HOME/.config/grove/sites/" 2>/dev/null)"
else
	skip "nothing is serving on :2019 — no live proxy to compare against"
fi

# --- teardown -------------------------------------------------------------------------------------
pkill -f "caddy run --config $S/caddy/Caddyfile" 2>/dev/null; pkill -f "$S/upstream.py" 2>/dev/null
rm -rf "$S" "$STORE"
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
