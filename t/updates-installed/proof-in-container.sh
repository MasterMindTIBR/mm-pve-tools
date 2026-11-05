#!/bin/sh
set -eu

export MM_PVE_CONFIG_DIR=/etc/pve/mm-tools
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

work=/tmp/mm-updates-proof
rm -rf "$work"
mkdir -p "$work/pkg-old/DEBIAN" "$work/pkg-new/DEBIAN" /opt/mm-local

cat >"$work/pkg-old/DEBIAN/control" <<'EOF'
Package: mm-update-proof
Version: 1.0
Section: misc
Priority: optional
Architecture: all
Description: local update proof package
EOF
cat >"$work/pkg-new/DEBIAN/control" <<'EOF'
Package: mm-update-proof
Version: 2.0
Section: misc
Priority: optional
Architecture: all
Description: local update proof package
EOF
cat >"$work/pkg-new/DEBIAN/postinst" <<'EOF'
#!/bin/sh
sleep 5
exit 0
EOF
chmod 0755 "$work/pkg-new/DEBIAN/postinst"
dpkg-deb --build "$work/pkg-old" "$work/mm-update-proof_1.0_all.deb" >/dev/null
dpkg-deb --build "$work/pkg-new" "$work/mm-update-proof_2.0_all.deb" >/dev/null
cp "$work"/mm-update-proof_*.deb /opt/mm-local/
(cd /opt/mm-local && dpkg-scanpackages . /dev/null > Packages)
gzip -9c /opt/mm-local/Packages > /opt/mm-local/Packages.gz
printf '%s\n' 'deb [trusted=yes] file:/opt/mm-local ./' > /etc/apt/sources.list.d/mm-local.list
rm -f /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list
dpkg -i "$work/mm-update-proof_1.0_all.deb"
apt-get update -qq

printf '%s\n' '{"modules":{"updates":1}}' | mm-pve config set --stdin >/dev/null
node=$(hostname)
first=$(mm-pve --json updates run --node "$node")
job=$(printf '%s\n' "$first" | sed -n 's/.*"job" *: *"\([0-9a-f-]*\)".*/\1/p')
[ -n "$job" ] || { echo 'job não foi criado' >&2; exit 1; }

second_rc=0
mm-pve --json updates run --node "$node" >/tmp/mm-updates-second.out 2>&1 || second_rc=$?
[ "$second_rc" -ne 0 ] || { echo 'segundo job foi aceito durante o primeiro' >&2; cat /tmp/mm-updates-second.out >&2; exit 1; }

state=/etc/pve/mm-tools/updates/$node.json
final_state=
for _ in $(seq 1 120); do
    if [ -f "$state" ]; then
        final_state=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("state"))' "$state")
        case "$final_state" in
            succeeded|failed|lost) break ;;
        esac
    fi
    sleep 1
done
if [ "$final_state" != succeeded ]; then
    echo "job terminou em ${final_state:-desconhecido}; log:" >&2
    log=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("log", ""))' "$state" 2>/dev/null || true)
    if [ -n "$log" ] && [ -f "$log" ]; then cat "$log" >&2; fi
    exit 1
fi
log=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["log"])' "$state")
[ -f "$log" ] || { echo "log ausente: $log" >&2; exit 1; }
grep -Fq 'apt-get' "$log" || { echo 'log não registra APT' >&2; exit 1; }
dpkg-query -W -f='${Version}\n' mm-update-proof | grep -qx '2.0' || {
    echo 'pacote dummy não subiu para 2.0' >&2
    exit 1
}
echo 'UPDATES INSTALLED OK: systemd-run, succeeded, log e reserva por node'
