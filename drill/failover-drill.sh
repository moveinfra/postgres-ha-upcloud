#!/bin/bash
# Failover drill: power off the primary without warning while a client writes, and measure what the client saw.
# Run from the directory with the Terraform state, from a machine inside admin_cidr.
#   ./drill/failover-drill.sh            # 120 s of writes, primary killed after 30 s
set -euo pipefail
DURATION=${DURATION:-120}
KILL_AFTER=${KILL_AFTER:-30}
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"

targets=$(terraform output -json ssh)
name=$(terraform output -raw name)
monitor=$(echo "$targets" | jq -r --arg h "$name-monitor" '.[$h]')
first_db=$(echo "$targets" | jq -r --arg h "$name-1" '.[$h]')

echo "== cluster before"
$SSH "$first_db" "sudo -u postgres patronictl -c /etc/patroni/config.yml list"
leader=$($SSH "$first_db" "curl -s http://127.0.0.1:8008/cluster" | jq -r '.members[] | select(.role=="leader") | .name')
leader_ssh=$(echo "$targets" | jq -r --arg h "$leader" '.[$h]')
echo "== primary is $leader"

echo "== writer starts on the monitor node ($DURATION s, one insert every 0.2 s)"
$SSH "$monitor" "sudo pg-drill-writer $DURATION" >/tmp/pg-drill-result.txt &
writer=$!
sleep "$KILL_AFTER"

echo "== $(date -u +%T) powering off $leader with no shutdown"
$SSH "$leader_ssh" "sudo sh -c 'echo 1 > /proc/sys/kernel/sysrq; echo o > /proc/sysrq-trigger'" >/dev/null 2>&1 &
wait "$writer" || true

echo "== what the client saw"
cat /tmp/pg-drill-result.txt
echo "== cluster after"
survivor=$(echo "$targets" | jq -r --arg l "$leader" --arg m "$name-monitor" 'to_entries[] | select(.key != $l and .key != $m) | .value' | head -1)
$SSH "$survivor" "sudo -u postgres patronictl -c /etc/patroni/config.yml list"
echo
echo "$leader is powered off. Start it again (upctl server start $leader) and watch it rejoin as a replica:"
echo "  $SSH $survivor 'sudo -u postgres patronictl -c /etc/patroni/config.yml list'"
