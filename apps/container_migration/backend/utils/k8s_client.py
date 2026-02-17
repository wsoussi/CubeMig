from kubernetes import client, config
from utils.constants import CLUSTER_1, CLUSTER_2, CLUSTER_SEV_SNP

class K8sClient:
    def __init__(self, kube_config_path: str):
        config.load_kube_config(config_file=kube_config_path)
        self.client1 = client.CoreV1Api(
            api_client=config.new_client_from_config(context=CLUSTER_1))
        self.client2 = client.CoreV1Api(
            api_client=config.new_client_from_config(context=CLUSTER_2))
        self.client_sev_snp = client.CoreV1Api(
            api_client=config.new_client_from_config(context=CLUSTER_SEV_SNP))
        self.active_client = self.client1

    def get_client(self, target_cluster: str):
        if target_cluster == CLUSTER_1:
            return self.client1
        elif target_cluster == CLUSTER_2:
            return self.client2
        elif target_cluster == CLUSTER_SEV_SNP:
            return self.client_sev_snp
        else:
            raise ValueError(f"Invalid cluster choice: {target_cluster}")

k8s_client = K8sClient('/home/ubuntu/.kube/config')