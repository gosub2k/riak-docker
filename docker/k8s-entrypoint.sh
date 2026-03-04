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
  # Should really just join node 0 but if down maybe ok to join other nodes.
  for i in "0"; do
    local try_host=$base_host-$i.${RIAK_SUBDOMAIN}
    echo "Trying to join cluster: $try_host"
    if [ "$base_host-$i" = "$POD_NAME" ]; then
      echo "I am $try_host, so not trying to join"
      return 0
    fi
    if ! grep error <(riak-admin cluster join "riak@$try_host"); then
      echo "Joined cluster"
      if riak-admin cluster plan && riak-admin cluster commit; then
        echo "Committed to cluster"
        return 0
      fi
    else
      echo "Failed to join cluster at $try_host"
    fi
    sleep 10
  done
  return 1
}

# Try to join cluster
while ! join_cluster; do
  echo "Couldn't join cluster, sleeping..."
  sleep 30
done

# Keep alive and periodically log cluster status
while true; do
  echo -n "sleeping..."
  sleep 30
  if ! riak ping; then
    echo "$(date): riak ping failed!"
  fi
  echo "$(date): cluster status:"
  riak-admin cluster status
done
