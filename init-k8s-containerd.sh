#!/bin/bash

function INFO() { echo -e "\e[0;32m${1}\e[0m"; }
function DONE() { echo -e "\e[0;34m[✓] Done! \e[0m\n"; }
function get_latest_version() {
    curl -sSL "https://api.github.com/repos/$1/releases" | jq -r '[.[] | select(.prerelease == false)][0].tag_name'
}

if [ $# -ne 1 ] || ([ $# -eq 1 ] && [ $1 != "master" ] && [ $1 != "node" ]); then
    echo "Usage: $0 <master|node>"
    exit 1
fi

yum install -y jq conntrack ipset ipvsadm ntpdate socat

ARCH="amd64"
# RUNC_VERSION="v1.1.12"
RUNC_VERSION=$(get_latest_version "opencontainers/runc")
# CONTAINERD_VERSION="v1.6.32"
CONTAINERD_VERSION=$(get_latest_version "containerd/containerd")
# CNI_PLUGINS_VERSION="v1.5.0"
CNI_PLUGINS_VERSION=$(get_latest_version "containernetworking/plugins")
# CRICTL_VERSION="v1.30.0"
CRICTL_VERSION=$(get_latest_version "kubernetes-sigs/cri-tools")
# KUBE_RELEASE_VERSION="v0.16.9"
KUBE_RELEASE_VERSION=$(get_latest_version "kubernetes/release")
# K8S_RELEASE_VERSION="v1.30.1"
K8S_RELEASE_VERSION="$(curl -sSL https://dl.k8s.io/release/stable.txt)"
CNI_DIR="/opt/cni/bin"
CNI_CONF_DIR="/etc/cni/net.d"
BIN_DIR="/usr/local/bin"
POD_NET_CIDR="10.0.0.0/16"

INFO "[*] CNI_PLUGINS_VERSION $CNI_PLUGINS_VERSION"
INFO "[*] CRICTL_VERSION $CRICTL_VERSION"
INFO "[*] KUBE_RELEASE_VERSION $KUBE_RELEASE_VERSION"
INFO "[*] K8S_RELEASE_VERSION $K8S_RELEASE_VERSION"
INFO "[*] CONTAINERD_VERSION $CONTAINERD_VERSION"
INFO "[*] RUNC_VERSION $RUNC_VERSION"
INFO "Press any key to continue ..."
read

INFO "[*] Stop firewalld"
systemctl stop firewalld
systemctl disable firewalld
DONE

INFO "[*] Turn off swap"
swapoff -a
sed -ri 's/.*swap.*/#&/' /etc/fstab
sysctl -w vm.swappiness=0
cat /etc/fstab
DONE

INFO "[*] Turn off SELinux"
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
DONE

INFO "[*] Write sysctl configurations"
cat > /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
vm.swappiness=0
fs.may_detach_mounts = 1
vm.overcommit_memory=1
vm.panic_on_oom=0
fs.inotify.max_user_watches=89100
fs.file-max=52706963
fs.nr_open=52706963
net.netfilter.nf_conntrack_max=2310720

net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl =15
net.ipv4.tcp_max_tw_buckets = 36000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_orphans = 327680
net.ipv4.tcp_orphan_retries = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.ip_conntrack_max = 65536
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_timestamps = 0
net.core.somaxconn = 16384

net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 0
EOF
DONE

INFO "[*] Set auto-load modules"
modprobe overlay
modprobe br_netfilter

cat > /etc/modules-load.d/containerd.conf <<EOF
overlay
br_netfilter
EOF
DONE

INFO "[*] Set IPVS modules"
modprobe ip_vs
modprobe ip_vs_rr
modprobe ip_vs_wrr
modprobe ip_vs_sh
modprobe nf_conntrack

cat > /etc/sysconfig/modules/ipvs.modules <<EOF
#!/bin/bash
modprobe -- ip_vs
modprobe -- ip_vs_rr
modprobe -- ip_vs_wrr
modprobe -- ip_vs_sh
modprobe -- nf_conntrack
EOF

chmod +x /etc/sysconfig/modules/ipvs.modules
. /etc/sysconfig/modules/ipvs.modules
lsmod | grep -e ip_vs -e nf_conntrack
DONE

INFO "[*] Apply sysctl configurations"
sysctl -p /etc/sysctl.d/kubernetes.conf
DONE

INFO "[*] Write k8s configurations"
cat > /etc/init.d/k8s.sh <<EOF
#!/bin/sh
modprobe br_netfilter
sysctl -w net.bridge.bridge-nf-call-ip6tables = 1
sysctl -w net.bridge.bridge-nf-call-iptables = 1
EOF
chmod +x /etc/init.d/k8s.sh
DONE

INFO "[*] Write service for k8s configurations"
cat > /etc/systemd/system/br_netfilter.service <<EOF
[Unit]
Description=To enable the core module br_netfilter when reboot
After=default.target
[Service]
ExecStart=/etc/init.d/k8s.sh
[Install]
WantedBy=default.target
EOF
DONE

INFO "[*] Enable service"
systemctl daemon-reload
systemctl enable br_netfilter.service
DONE

INFO "[*] Modify /etc/sysctl.conf"
sed -i "s/net.ipv4.ip_forward=0/net.ipv4.ip_forward=1/g" /etc/sysctl.conf
sed -i 12a\vm.swappiness=0 /etc/sysctl.conf
DONE

INFO "[*] Install containerd"
wget "https://gh.con.sh/https://github.com/containerd/containerd/releases/download/${CONTAINERD_VERSION}/containerd-$(echo $CONTAINERD_VERSION | cut -c 2-)-linux-${ARCH}.tar.gz" -O containerd.tar.gz
tar Cxzvf /usr/local containerd.tar.gz
wget "https://raw.githubusercontent.com/containerd/containerd/${CONTAINERD_VERSION}/containerd.service" -O  /etc/systemd/system/containerd.service
mkdir -p /etc/containerd
systemctl daemon-reload
systemctl enable --now containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sed -i 's/disabled_plugins/# disabled_plugins/g' /etc/containerd/config.toml
sed -i 's#registry.k8s.io#registry.aliyuncs.com/google_containers#g' /etc/containerd/config.toml
systemctl daemon-reload
systemctl restart containerd
rm -f containerd.tar.gz
DONE

INFO "[*] Install RUNC"
wget "https://gh.con.sh/https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.amd64" -O runc
install -m 755 runc /usr/local/sbin/runc
rm -f runc
DONE

INFO "[*] Install CNI plugin"
mkdir -p "$CNI_DIR"
curl -L "https://gh.con.sh/https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz" | tar -C "$CNI_DIR" -xz
DONE

INFO "[*] Install kubectl"
curl -LO "https://dl.k8s.io/release/${K8S_RELEASE_VERSION}/bin/linux/amd64/kubectl"
curl -LO "https://dl.k8s.io/${K8S_RELEASE_VERSION}/bin/linux/amd64/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
rm -f kubectl kubectl.sha256
DONE

INFO "[*] Install crictl"
mkdir -p "$BIN_DIR"
curl -L "https://gh.con.sh/https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz" | tar -C $BIN_DIR -xz
DONE

INFO "[*] Install kubeadm and kubelet"
cd $BIN_DIR
curl -L --remote-name-all https://dl.k8s.io/release/${K8S_RELEASE_VERSION}/bin/linux/${ARCH}/{kubeadm,kubelet}
chmod +x {kubeadm,kubelet}

curl -sSL "https://raw.gitmirror.com/kubernetes/release/${KUBE_RELEASE_VERSION}/cmd/krel/templates/latest/kubelet/kubelet.service" | sed "s:/usr/bin:${BIN_DIR}:g" | tee /usr/lib/systemd/system/kubelet.service
mkdir -p /usr/lib/systemd/system/kubelet.service.d
curl -sSL "https://raw.gitmirror.com/kubernetes/release/${KUBE_RELEASE_VERSION}/cmd/krel/templates/latest/kubeadm/10-kubeadm.conf" | sed "s:/usr/bin:${BIN_DIR}:g" | tee /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
systemctl enable --now kubelet
DONE

# Reference: https://github.com/cilium/cilium/issues/22933
INFO "[*] Change permissions of /opt/cni"
chown -R $(id -n -u):$(id -n -g) /opt/cni
DONE

INFO "[*] Pull images"
kubeadm config images pull --image-repository=registry.aliyuncs.com/google_containers
DONE

if [ "$1" = "master" ]; then
    INFO "[*] Initiate k8s master"
    kubeadm init --pod-network-cidr=$POD_NET_CIDR --image-repository=registry.aliyuncs.com/google_containers
    mkdir -p $HOME/.kube
    cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config
    DONE
elif [ "$1" = "node" ]; then
    INFO "[*] Use command from master (kubeadm join ...) to initiate k8s node."
    DONE
fi

cd ~
