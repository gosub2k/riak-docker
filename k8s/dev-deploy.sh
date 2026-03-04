#!/bin/bash
set -e

IMAGE="riak-local:dev"
NAMESPACE="bangfs"
STATEFULSET="riak"
CONTAINER="riak"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_DIR="$SCRIPT_DIR/../docker"

echo "Building image..."
docker build -t "$IMAGE" "$DOCKER_DIR"

echo "Importing image into microk8s..."
docker save "$IMAGE" | microk8s ctr image import -

echo "Applying k8s manifests..."
microk8s kubectl create namespace "$NAMESPACE" 2>/dev/null || true
microk8s kubectl apply -f "$SCRIPT_DIR/riak_conf.yaml"
microk8s kubectl apply -f "$SCRIPT_DIR/riak.yaml"

echo "Patching statefulset to use local image..."
microk8s kubectl -n "$NAMESPACE" set image "statefulset/$STATEFULSET" "$CONTAINER=$IMAGE"
microk8s kubectl -n "$NAMESPACE" patch statefulset "$STATEFULSET" \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"'"$CONTAINER"'","imagePullPolicy":"Never"}]}}}}'

echo "Restarting statefulset..."
microk8s kubectl -n "$NAMESPACE" rollout restart "statefulset/$STATEFULSET"
microk8s kubectl -n "$NAMESPACE" rollout status "statefulset/$STATEFULSET"

echo "Done. Pods:"
microk8s kubectl -n "$NAMESPACE" get pods -l app=riak
