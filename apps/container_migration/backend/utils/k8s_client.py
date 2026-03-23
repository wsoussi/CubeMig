from kubernetes import client, config
from kubernetes.config.config_exception import ConfigException

class K8sClient:
    def __init__(self, kube_config_path: str):
        self.kube_config_path = kube_config_path
        self.clients = {}
        self._refresh_clients()

    def _refresh_clients(self):
        self.clients = {}
        try:
            contexts, _ = config.list_kube_config_contexts(config_file=self.kube_config_path)
        except ConfigException as exc:
            raise RuntimeError(f"Failed to read kube contexts from {self.kube_config_path}: {str(exc)}") from exc

        if not contexts:
            raise RuntimeError(f"No Kubernetes contexts found in {self.kube_config_path}")

        for context in contexts:
            context_name = context.get("name")
            if not context_name:
                continue
            self.clients[context_name] = client.CoreV1Api(
                api_client=config.new_client_from_config(
                    config_file=self.kube_config_path,
                    context=context_name
                )
            )

    def get_client(self, target_cluster: str):
        client_for_cluster = self.clients.get(target_cluster)
        if not client_for_cluster:
            raise ValueError(f"Invalid cluster choice: {target_cluster}")
        return client_for_cluster

    def list_clusters(self):
        return sorted(self.clients.keys())

    def has_cluster(self, cluster_name: str):
        return cluster_name in self.clients

k8s_client = K8sClient('/home/ubuntu/.kube/config')