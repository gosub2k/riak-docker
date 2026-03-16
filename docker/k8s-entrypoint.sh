#!/bin/bash
set -e

RIAK_CONF=/opt/riak/etc/riak.conf
RIAK_SUBDOMAIN=riak-headless

# Data from configMap goes into config file...
if ! [ -z "$RIAK_CONF_INITIAL_DATA" ]; then
  echo "Updated riak conf"
  echo "$RIAK_CONF_INITIAL_DATA" > $RIAK_CONF
fi

# Custom riak host name
if ! [ -z "$POD_NAME" ]; then
  RIAK_ID="${POD_NAME}.${RIAK_SUBDOMAIN}"
  sed -i.k8sbak -e "s/riak@127.0.0.1/riak@${RIAK_ID}/" $RIAK_CONF
fi

# Start riak
riak daemon
while ! riak ping; do
  echo "Waiting for riak to come up..."
  sleep 10
done
echo "riak is up!"

# Check if this node is in 'leaving' state from a previous crash/restart.
# If so, force-remove it and re-join cleanly.
member_status=$(riak-admin member-status 2>/dev/null | grep "riak@${RIAK_ID}" | awk '{print $2}') || true
if [ "$member_status" = "leaving" ]; then
  echo "Node is in 'leaving' state — clearing stale cluster membership..."
  riak-admin cluster force-remove "riak@${RIAK_ID}" || true
  riak-admin cluster plan || true
  riak-admin cluster commit || true
  # Restart riak so it comes up with a clean ring
  riak stop
  sleep 5
  riak daemon
  while ! riak ping; do
    echo "Waiting for riak to come back up after force-remove..."
    sleep 10
  done
  echo "riak restarted with clean state"
fi

wait_for_no_pending() {
  # Wait until there are no pending transfers so our plan/commit can succeed
  local max_wait=${1:-300}
  local elapsed=0
  while [ $elapsed -lt $max_wait ]; do
    # Check if any node has a non-zero pending value
    if ! riak-admin member-status 2>/dev/null | awk '/riak@/{print $5}' | grep -qvE '^(--|-|0\.0)$'; then
      echo "No pending transfers, safe to plan"
      return 0
    fi
    echo "Waiting for pending transfers to settle... (${elapsed}s/${max_wait}s)"
    sleep 15
    elapsed=$((elapsed + 15))
  done
  echo "Warning: timed out waiting for pending transfers"
  return 1
}

try_join_node() {
  local target_host="$1"
  local join_output
  join_output=$(riak-admin cluster join "riak@$target_host" 2>&1) || true
  echo "  join response: $join_output"

  if echo "$join_output" | grep -q "^Success"; then
    echo "Join staged to $target_host, waiting for pending transfers to clear..."
    wait_for_no_pending 300
    if riak-admin cluster plan && riak-admin cluster commit; then
      echo "Committed to cluster"
      return 0
    else
      echo "Plan/commit failed, will retry"
      return 1
    fi
  elif echo "$join_output" | grep -q "already a member"; then
    echo "Already joined, just need to plan/commit"
    wait_for_no_pending 300
    if riak-admin cluster plan && riak-admin cluster commit; then
      echo "Committed to cluster"
      return 0
    fi
    return 1
  fi
  return 1
}

join_cluster() {
  if [ -z "$POD_NAME" ]; then
    echo POD_NAME not set, assume this is not K8S and no cluster
    return 0
  fi

  # Check if already a member of a multi-node cluster (not just a standalone node)
  local cluster_members
  cluster_members=$(riak-admin member-status 2>/dev/null | grep -c "riak@") || true
  if [ "$cluster_members" -gt 1 ]; then
    echo "Already a member of a ${cluster_members}-node cluster, skipping join"
    return 0
  fi

  local base_host=${POD_NAME%%-*}  # extract stateful set name
  local SEED_NODE="${base_host}-0.${RIAK_SUBDOMAIN}"
  local FALLBACK_NODE="${base_host}-1.${RIAK_SUBDOMAIN}"

  # Skip join if we ARE the seed node
  if [ "${base_host}-0" = "$POD_NAME" ]; then
    echo "I am the seed node ($SEED_NODE), not joining anyone"
    return 0
  fi

  # Always try SEED_NODE first. Only fall back to FALLBACK_NODE if
  # SEED_NODE has been unreachable for a long time.
  SEED_FAIL_COUNT=${SEED_FAIL_COUNT:-0}

  # After 10 consecutive failures (~5 min), try FALLBACK_NODE
  if [ "$SEED_FAIL_COUNT" -lt 10 ]; then
    echo "Trying to join seed node: $SEED_NODE"
    if try_join_node "$SEED_NODE"; then
      SEED_FAIL_COUNT=0
      return 0
    else
      SEED_FAIL_COUNT=$((SEED_FAIL_COUNT + 1))
      echo "Failed to join seed node (attempt $SEED_FAIL_COUNT)"
      return 1
    fi
  fi

  # Fallback: SEED_NODE has been down for a while — try FALLBACK_NODE,
  # but ONLY if it's already part of a cluster that contains SEED_NODE.
  # This prevents split-brain where two standalone nodes form separate clusters.
  echo "Seed node unreachable for $SEED_FAIL_COUNT attempts, trying fallback..."

  if [ "${base_host}-1" = "$POD_NAME" ]; then
    echo "I am the fallback node ($FALLBACK_NODE), can't join myself — will keep retrying seed"
    return 1
  fi

  echo "Trying fallback node: $FALLBACK_NODE"
  local join_output
  join_output=$(riak-admin cluster join "riak@$FALLBACK_NODE" 2>&1) || true
  echo "  join response: $join_output"

  if echo "$join_output" | grep -q "^Success"; then
    # Verify the cluster we're joining actually contains SEED_NODE
    # (meaning FALLBACK_NODE previously joined SEED_NODE's cluster)
    sleep 5
    if riak-admin member-status 2>/dev/null | grep -q "riak@${base_host}-0"; then
      echo "Fallback cluster contains seed node — safe to proceed"
      wait_for_no_pending 300
      if riak-admin cluster plan && riak-admin cluster commit; then
        echo "Committed to cluster via fallback"
        SEED_FAIL_COUNT=0
        return 0
      fi
    else
      echo "WARNING: fallback cluster does NOT contain seed node — aborting to prevent split-brain"
      riak-admin cluster leave 2>/dev/null || true
      riak-admin cluster plan 2>/dev/null || true
      riak-admin cluster commit 2>/dev/null || true
      return 1
    fi
  fi

  SEED_FAIL_COUNT=$((SEED_FAIL_COUNT + 1))
  return 1
}

# Try to join cluster
SEED_FAIL_COUNT=0
while ! join_cluster; do
  echo "Couldn't join cluster, sleeping..."
  sleep 30
done

# Keep alive and periodically log cluster status
while true; do
  sleep 30

  echo ""
  echo "=========================================="
  echo "  $(date)"
  echo "=========================================="

  if ! riak ping; then
    echo "  PING: FAILED"
  else
    echo "  PING: ok"
  fi

  echo ""
  echo "-- Member Status -------------------------"
  riak-admin member-status 2>/dev/null || echo "  (unavailable)"

  echo ""
  echo "-- Ring Status ---------------------------"
  riak-admin ring-status 2>/dev/null | head -30 || echo "  (unavailable)"

  echo "=========================================="
done
