# Variables
sourceCluster = cluster1
targetCluster = cluster-sev-snp
mmtNamespace = mmt
appNamespace = istio-enabled

# Switch to sourceCluster cluster
kubectl config use-context $sourceCluster
# Create mmt namespace and enable istio injection
kubectl create namespace $mmtNamespace

# Deploy Kafka and zookeeper
kubectl apply -f ./kafka.yml -n $mmtNamespace
# Deploy MongoDB
kubectl apply -f ./mongo.yml -n $mmtNamespacet
# Wait for the MongoDB Pod being available (~20 seconds)
echo "Waiting for MongoDB pod to become Ready"
  kubectl wait \
    --namespace mmt \
    --for=condition=ready pod \
    --selector=app=mmt-database \
    --timeout=120s

# Deploy MMT-Operator
kubectl apply -f ./mmt-operator.yml -n $mmtNamespace
