#!/bin/bash

function INFO() { echo -e "\e[0;32m${1}\e[0m"; }
function DONE() { echo -e "\e[0;34m[✓] Done! \e[0m\n"; }
function get_latest_version() {
    curl -sSL "https://api.github.com/repos/$1/releases" | jq -r '[.[] | select(.prerelease == false)][0].tag_name'
}

# CALICO_VERSION="v3.27.2"
CALICO_VERSION=$(get_latest_version "projectcalico/calico")
POD_NET_CIDR="10.0.0.0/16"

INFO "[*] CALICO_VERSION $CALICO_VERSION"
read

INFO "[*] Configure NetworkManager"
cat > /etc/NetworkManager/conf.d/calico.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:tunl*;interface-name:vxlan.calico;interface-name:vxlan-v6.calico;interface-name:wireguard.cali;interface-name:wg-v6.cali
EOF
systemctl restart NetworkManager
DONE

INFO "[*] Initiate Calico"
kubectl create -f "https://raw.gitmirror.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
curl -LO "https://raw.gitmirror.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml"
sed -i "s#cidr: .*#cidr: ${POD_NET_CIDR}#g" custom-resources.yaml
cat custom-resources.yaml
kubectl create -f custom-resources.yaml
rm -f custom-resources.yaml
cd /usr/local/bin
curl -L "https://gh.con.sh/https://github.com/projectcalico/calico/releases/download/${CALICO_VERSION}/calicoctl-linux-amd64" -o calicoctl
chmod +x calicoctl
watch 'echo "Wait until each pod has the STATUS of Running." && kubectl get pods -n calico-system'
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
kubectl taint nodes --all node-role.kubernetes.io/master-
DONE

cd ~
