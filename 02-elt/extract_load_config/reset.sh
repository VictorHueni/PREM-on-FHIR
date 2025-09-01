# 0) Vars
export KUBECONFIG="$HOME/.airbyte/abctl/abctl.kubeconfig"
NS=airbyte-abctl

# 1) Best-effort uninstall via abctl (okay if it fails)
abctl local uninstall -v || true

# 2) Helm cleanup (okay if not installed)
helm -n "$NS" uninstall airbyte-abctl || true
helm -n ingress-nginx uninstall ingress-nginx || true

# 3) K8s namespaces (remove everything left behind)
kubectl delete ns "$NS" --ignore-not-found
kubectl delete ns ingress-nginx --ignore-not-found

# 4) Remove kube context/cluster/user entries created for this kind cluster
kubectl config delete-context kind-airbyte-abctl 2>/dev/null || true
kubectl config delete-cluster kind-airbyte-abctl 2>/dev/null || true
kubectl config unset users.kind-airbyte-abctl 2>/dev/null || true

# 5) Delete the kind cluster container(s)
kind delete cluster --name airbyte-abctl || true

# 6) Stop any lingering port-forwards (best-effort)
pkill -f "kubectl.*port-forward" 2>/dev/null || true

# 7) Remove Airbyte’s WSL data/cache (THIS WIPES LOCAL AIRBYTE DATA)
sudo rm -rf "$HOME/.airbyte"

# 8) Docker cleanup (be cautious: prunes all *unused* resources)
docker ps -a --format '{{.ID}}\t{{.Names}}' | grep -Ei 'airbyte|temporal|kind' || true
docker rm -f $(docker ps -aq --filter "name=airbyte") 2>/dev/null || true
docker rm -f $(docker ps -aq --filter "name=temporal") 2>/dev/null || true
# remove the kind control-plane container if still present
docker rm -f airbyte-abctl-control-plane 2>/dev/null || true

# Remove images (only Airbyte/ingress/kind ones)
docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep -Ei 'airbyte|ingress-nginx|temporalio|kindest' | awk '{print $2}' | xargs -r docker rmi -f

# Remove unused volumes & networks (optional but tidy)
docker volume prune -f
docker network prune -f
# Big hammer (optional): remove *all* unused images/containers/networks/cache
# docker system prune -af --volumes

# 9) Sanity checks
echo "Clusters:" && kind get clusters || true
echo "Kube contexts:" && kubectl config get-contexts || true
echo "Docker containers (should be empty for airbyte/kind):" && docker ps -a | egrep -i 'airbyte|kind' || echo "none"


# who’s using 8000?
sudo ss -ltnp '( sport = :8000 )'
# or
sudo lsof -iTCP:8000 -sTCP:LISTEN
# then kill it (replace <pid>)
sudo kill -9 <pid>

