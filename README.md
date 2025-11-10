1. Download govc and talosctl
```
curl -L -o - "https://github.com/vmware/govmomi/releases/latest/download/govc_$(uname -s)_$(uname -m).tar.gz" | sudo tar -C /usr/local/bin -xvzf - govc

curl -sL https://talos.dev/install | sh
```
2. get cp.patch.yaml
```
curl -fsSLO https://raw.githubusercontent.com/siderolabs/talos/refs/tags/v1.11.0/website/content/v1.8/talos-guides/install/virtualized-platforms/vmware/cp.patch.yaml
```
3. edit cp.patch.yaml
```
- op: add
  path: /machine/network
  value:
    interfaces:
    - interface: eth0
      dhcp: true
      vip:
        ip: <VIP>

- op: replace
  path: /cluster/extraManifests
  value:
    - "https://raw.githubusercontent.com/siderolabs/talos-vmtoolsd/refs/tags/v1.4.0/deploy/latest.yaml"
```
4. create patch.yaml
```
cat <<EOF | sudo tee patch.yaml
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
EOF
```
5. upload ova
```
./mgmt.sh upload_ova
```
6. gen config
```
./mgmt.sh gen_config
```

7. edit controlplane.yaml
```
cluster.allowSchedulingOnControlPlanes to true
```

8. create
```
./mgmt.sh create
```

9. bootstrap
```
./mgmt.sh bootstrap
```

10. kubeconfig
```
./mgmt.sh kubeconfig
```

11. labeled
```
./mgmt.sh labeled
```


11. Kubectl and Helm installation
```

curl -LO https://dl.k8s.io/release/v1.33.4/bin/linux/amd64/kubectl
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client


# Helm installation
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Add cilium repo
helm repo add cilium https://helm.cilium.io/
helm repo update
```

12. Cillium installation
```
helm install \
    cilium \
    cilium/cilium \
    --version 1.18.0 \
    --namespace kube-system \
    --set ipam.mode=kubernetes \
    --set k8s.requireIPv4PodCIDR=true \
    --set kubeProxyReplacement=true \
    --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
    --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
    --set cgroup.autoMount.enabled=false \
    --set cgroup.hostRoot=/sys/fs/cgroup \
    --set k8sServiceHost=localhost \
    --set operator.tolerateMaster=true \
    --set k8sServicePort=7445
```

13. cillium connectivity testing
```
# Install Cilium CLI
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

# Check Cilium status and connectivity
cilium status --wait
cilium connectivity test


# Add label on cilium-test-1 namespace
kubectl label namespace cilium-test-1 pod-security.kubernetes.io/enforce=privileged
```

14. Config vmware tools guest agent
```
# Create new talos config for secret
talosctl --talosconfig talosconfig -n <control plane IP> config new vmtoolsd-secret.yaml --roles os:admin

# Create secret
kubectl -n kube-system create secret generic talos-vmtoolsd-config --from-file=talosconfig=vmtoolsd-secret.yaml
```

15. Deploy ingress nginx
```
# Add Helm Repository
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Install ingress-nginx with helm
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.replicaCount=3 \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443
```