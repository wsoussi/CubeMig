#!/bin/bash

sourceCluster="cluster1"
targetCluster="cluster2"
namespace="istio-enabled"

for i in {1..20}
do
  kubectl config use-context "$sourceCluster"

  podName=$(kubectl get pods -n "$namespace" --no-headers | awk '/^routing-demo/ {print $1; exit}')

  ../migration/single-migration.sh "$podName" --source-cluster "$sourceCluster" --dest-cluster "$targetCluster" --namespace "$namespace"

  kubectl config use-context "$targetCluster"

  kubectl delete pod routing-demo-restore -n "$namespace"
  kubectl wait --for=delete pod/routing-demo-restore -n "$namespace"
done
