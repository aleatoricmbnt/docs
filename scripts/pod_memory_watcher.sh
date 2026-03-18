#!/usr/bin/env bash
# Usage: ./pod_memory_watcher.sh <pod-name>
# Runs the loop inside the container (one exec). Shows current, anon, inactive_file, active_file in MiB (cgroup values are in bytes).
# Namespace: system-agent (set NAMESPACE env to override)
# mshytse-ns-playground

NAMESPACE="${NAMESPACE:-mshytse-ns-playground}"
POD_NAME="${1:?Usage: $0 <pod-name>}"

read -r -d '' INNER_SCRIPT << 'ENDINNER'
CURRENT_FILE=/sys/fs/cgroup/memory.current
STAT_FILE=/sys/fs/cgroup/memory.stat

while true; do
  current=0; anon=0; inactive_file=0; active_file=0
  [ -r "$CURRENT_FILE" ] && read -r current < "$CURRENT_FILE"
  if [ -r "$STAT_FILE" ]; then
    while read -r name value; do
      case "$name" in
        anon) anon=$value ;;
        inactive_file) inactive_file=$value ;;
        active_file) active_file=$value ;;
      esac
    done < "$STAT_FILE"
  fi

  current_mib=$(( current / 1048576 ))
  anon_mib=$(( anon / 1048576 ))
  inactive_mib=$(( inactive_file / 1048576 ))
  active_mib=$(( active_file / 1048576 ))

  printf "%s  current=%s MiB  anon=%s MiB  inactive_file=%s MiB  active_file=%s MiB\n" \
    "$(date '+%H:%M:%S' 2>/dev/null || echo -)" "$current_mib" "$anon_mib" "$inactive_mib" "$active_mib"
  sleep 1
done
ENDINNER

echo "Pod: $POD_NAME (ns: $NAMESPACE). Loop runs in container. Ctrl+C to stop."
echo ""

kubectl exec -it "$POD_NAME" -n "$NAMESPACE" -- /bin/sh -c "$INNER_SCRIPT"
