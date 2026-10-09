#!/bin/sh
# Run only on a designated test router with no modem attached.
set -eu
RU=/var/run/fm350
BACKUP=$(mktemp -d /tmp/fm350-smoke.XXXXXX)
cp /etc/config/fm350 "$BACKUP/config"
cleanup() {
	cp "$BACKUP/config" /etc/config/fm350
	/etc/init.d/fm350mgr restart
}
trap cleanup EXIT
wait_state() {
	i=0
	while [ "$i" -lt 20 ]; do
		[ "$(jq -r .state "$RU/state.json")" = "$1" ] && return 0
		sleep 1; i=$((i+1))
	done
	cat "$RU/state.json"; return 1
}
[ "$(jq -r .usb.present "$RU/state.json")" = false ] || { echo 'A modem is present; skipping switch tests'; exit 1; }
uci set fm350.global.enabled=0
uci set fm350.profile.enable=1
uci commit fm350
wait_state DISABLED
echo 'PASS manager-disabled'
# Stop the consumer to deterministically exercise a pending request over RPC.
/etc/init.d/fm350mgr stop
ubus call fm350 dial_op '{"action":"disable"}' | jq -e '.queued == true'
ubus call fm350 dial_op '{"action":"enable"}' | jq -e '.error != null'
/etc/init.d/fm350mgr start
i=0
while [ "$(uci -q get fm350.profile.enable)" != 0 ] && [ "$i" -lt 15 ]; do sleep 1; i=$((i+1)); done
[ "$(uci -q get fm350.profile.enable)" = 0 ]
echo 'PASS absent-disable-and-busy-RPC'
ubus call fm350 status '{"quick":1}' | jq -e '.state.state == "DISABLED"'
ubus call fm350 cell '{}' | jq -e '.cell == {}'
uci set fm350.global.enabled=1
uci set fm350.profile.enable=1
uci commit fm350
wait_state ABSENT
echo 'PASS manager-reenabled'
if /usr/lib/fm350/fm350.sh daemon; then
	echo 'FAIL duplicate daemon started'; exit 1
fi
echo 'PASS duplicate-daemon-rejected'
echo "Configuration backup: $BACKUP/config"
