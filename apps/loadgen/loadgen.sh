#!/bin/sh
# loadgen: the "robot customer". Steady, light traffic through the frontend.
# Env: TARGET (http://frontend:3000), SLEEP seconds between loops (1),
#      ADMIN_USER / ADMIN_PASSWORD (for the restock call)
#
# Admin can stop/start it from http://<frontend>/admin/ : we read GET /api/robot
# every 5th loop while running, and every 5 s while paused.
TARGET="${TARGET:-http://frontend:3000}"
SLEEP="${SLEEP:-1}"
ITEMS="apple banana cherry"

# PID 1 in a container ignores SIGTERM unless we handle it: exit fast on rollout
trap 'echo "stopping"; exit 0' TERM INT

robot_enabled() {
  # if frontend is unreachable, keep running (grep fails -> "enabled")
  ! curl -s --max-time 3 "$TARGET/api/robot" | grep -q '"enabled":false'
}

echo "loadgen -> $TARGET every ${SLEEP}s"
i=0
paused=0
while true; do
  if [ $paused -eq 1 ] || [ $((i % 5)) -eq 0 ]; then
    if robot_enabled; then
      [ $paused -eq 1 ] && echo "resumed by admin"
      paused=0
    else
      [ $paused -eq 0 ] && echo "paused by admin"
      paused=1
      sleep 5
      continue
    fi
  fi

  i=$((i + 1))
  # pick a random item and qty 1..3 (busybox sh has no $RANDOM: use /dev/urandom)
  r=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
  item=$(echo $ITEMS | cut -d' ' -f$((r % 3 + 1)))
  qty=$((r / 3 % 3 + 1))   # use a different part of r than item

  c1=$(curl -s -o /dev/null -w '%{http_code}' "$TARGET/api/items")
  c2=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$TARGET/api/orders" \
        -H 'content-type: application/json' -d "{\"item\":\"$item\",\"qty\":$qty}")
  echo "#$i items=$c1 order($item x$qty)=$c2"

  # keep stock from running out (admin-only endpoint)
  if [ $((i % 100)) -eq 0 ]; then
    c3=$(curl -s -o /dev/null -w '%{http_code}' -u "$ADMIN_USER:$ADMIN_PASSWORD" \
          -X POST "$TARGET/admin/api/restock")
    echo "#$i restock=$c3"
  fi
  sleep "$SLEEP"
done
