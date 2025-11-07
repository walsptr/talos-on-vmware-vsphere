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
./vmware.sh upload_ova
```
6. gen config
```
./vmware.sh gen_config
```
7. create
```
./vmware.sh create
```
8. bootstrap
```
./vmware.sh bootstrap
```
9. kubeconfig
```
./vmware.sh kubeconfig
```
10. labeled
```
./vmware.sh labeled
```