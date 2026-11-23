#!/bin/sh
# loadgen: steady, light traffic through the frontend.
# Env: TARGET (http://frontend:3000), SLEEP seconds between loops (1)
TARGET="${TARGET:-http://frontend:3000}"
SLEEP="${SLEEP:-1}"
ITEMS="apple banana cherry"

# PID 1 in a container ignores SIGTERM unless we handle it: exit fast on rollout
trap 'echo "stopping"; exit 0' TERM INT

echo "loadgen -> $TARGET every ${SLEEP}s"
i=0
while true; do
  i=$((i + 1))
  # pick a random item and qty 1..3 (busybox sh has no $RANDOM: use /dev/urandom)
  r=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
  item=$(echo $ITEMS | cut -d' ' -f$((r % 3 + 1)))
  qty=$((r / 3 % 3 + 1))   # use a different part of r than item

  c1=$(curl -s -o /dev/null -w '%{http_code}' "$TARGET/api/items")
  c2=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$TARGET/api/orders" \
        -H 'content-type: application/json' -d "{\"item\":\"$item\",\"qty\":$qty}")
  echo "#$i items=$c1 order($item x$qty)=$c2"

  # keep stock from running out
  if [ $((i % 100)) -eq 0 ]; then
    curl -s -o /dev/null -X POST "$TARGET/api/restock" && echo "#$i restocked"
  fi
  sleep "$SLEEP"
done
