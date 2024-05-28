#!/bin/bash

function INFO() { echo -e "\e[0;32m${1}\e[0m"; }
function DONE() { echo -e "\e[0;34m[✓] Done! \e[0m\n"; }
function get_latest_version() {
    curl -sSL "https://api.github.com/repos/$1/releases" | jq -r '[.[] | select(.prerelease == false)][0].tag_name'
}

# Usage function to display help message
usage() {
    echo "Usage: $0 master|node [--build] [--master-ip <ip>] [--token <token>] [--hash <hash>]"
    printf "    --build\tBuild iSulad intead of using existing RPM\n"
    printf "    --master-ip\tIP:PORT of master node, example: 127.0.0.1:6443\n"
    printf "    --token\tValue of --token in kubeadm join\n"
    printf "    --hash\tValue of --ca-cert-hash in kubeadm join, example: sha256:......\n"
    exit 1
}

# Initializing variables
BUILD_ISULAD=0
MASTER_IP=""
TOKEN=""
CERT_HASH=""

# Checking the first argument
if [ "$1" != "master" ] && [ "$1" != "node" ]; then
    echo "Error: The first argument must be 'master' or 'node'."
    usage
fi

ROLE="$1"
shift

# Parsing the remaining arguments
while (( "$#" )); do
    case "$1" in
        --build)
            BUILD_ISULAD=1
            shift
            ;;
        --master-ip)
            if [ "$ROLE" != "node" ]; then
                echo "Error: --master-ip is only valid when the first argument is 'node'."
                usage
            fi
            MASTER_IP="$2"
            shift 2
            ;;
        --token)
            if [ "$ROLE" != "node" ]; then
                echo "Error: --token is only valid when the first argument is 'node'."
                usage
            fi
            TOKEN="$2"
            shift 2
            ;;
        --hash)
            if [ "$ROLE" != "node" ]; then
                echo "Error: --hash is only valid when the first argument is 'node'."
                usage
            fi
            CERT_HASH="$2"
            shift 2
            ;;
        *)
            echo "Error: Invalid argument '$1'."
            usage
            ;;
    esac
done

# Validating required arguments for 'node' role
if [ "$ROLE" == "node" ]; then
    if [ -z "$MASTER_IP" ] || [ -z "$TOKEN" ] || [ -z "$CERT_HASH" ]; then
        echo "Error: --master-ip, --token, and --hash are required when the first argument is 'node'."
        usage
    fi
fi

yum install -y jq ipset ipvsadm ntpdate conntrack \
               socat ncurses ncurses-devel lxc lxc-libs \
               gmock gmock-devel runc libisula libisula-devel \
               http-parser-devel

RPM=~/rpmbuild
ARCH="amd64"
# CNI_PLUGINS_VERSION="v1.5.0"
CNI_PLUGINS_VERSION=$(get_latest_version "containernetworking/plugins")
# CRICTL_VERSION="v1.30.0"
CRICTL_VERSION=$(get_latest_version "kubernetes-sigs/cri-tools")
K8S_RELEASE_VERSION="1.29.1-4"
CNI_DIR="/opt/cni/bin"
CNI_CONF_DIR="/etc/cni/net.d"
BIN_DIR="/usr/local/bin"
POD_NET_CIDR="10.0.0.0/16"

INFO "[*] CNI_PLUGINS_VERSION $CNI_PLUGINS_VERSION"
INFO "[*] CRICTL_VERSION $CRICTL_VERSION"
INFO "[*] K8S_RELEASE_VERSION $K8S_RELEASE_VERSION"
INFO "Press any key to continue ..."
read

INFO "[*] Extract files"
cat data/rpm.tar.gz* > data/rpm.tar.gz
tar xzvf data/rpm.tar.gz -C data/
DONE

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
EOF
DONE

INFO "[*] Apply sysctl configurations"
modprobe overlay
modprobe br_netfilter
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

if [ $BUILD_ISULAD -eq 1 ]; then
    INFO "[*] BUILD_ISULAD is true"
    INFO "[*] Get source code of iSulad"

    mkdir -p $RPM/SOURCES
    mkdir -p $RPM/SPECS
    git clone https://gitee.com/huj13k4n9/iSulad.git
    dnf builddep -y iSulad/iSulad.spec
    DONE

    INFO "[*] Build and install iSulad"
    cd iSulad && git checkout fix_image_name_2.1.5
    ISULAD_VERSION=$(cat iSulad.spec | grep '%global _version' | awk '{ print $3 }')
    ISULAD_TAR_NAME=v$ISULAD_VERSION.tar.gz
    mv ../iSulad ../iSulad-v$ISULAD_VERSION
    tar -zcvf $ISULAD_TAR_NAME ../iSulad-v$ISULAD_VERSION/*
    mv -f $ISULAD_TAR_NAME $RPM/SOURCES
    cp iSulad.spec $RPM/SPECS
    rpmbuild -ba $RPM/SPECS/iSulad.spec
    rpm -Uvh $RPM/RPMS/x86_64/iSulad-$ISULAD_VERSION-1.x86_64.rpm
    cd ..
    DONE

    INFO "[*] Clean build files"
    rm -rf iSulad-v$ISULAD_VERSION $RPM
    DONE
else
    INFO "[*] BUILD_ISULAD is false"
    INFO "[*] Install iSulad"
    ISULAD_VERSION="2.1.5"
    yum install -y libisula grpc protobuf libcurl libseccomp libcap libselinux libwebsockets libarchive device-mapper runc lib-shim-v2
    rpm -Uvh data/iSulad-$ISULAD_VERSION-1.x86_64.rpm
    # yum install -y iSulad conntrack socat
    DONE
fi

INFO "[*] Edit iSulad configurations"
cp data/daemon.json /etc/isulad/daemon.json
systemctl restart isulad
DONE

# INFO "[*] Install kubectl"
# curl -LO "https://dl.k8s.io/release/${K8S_RELEASE_VERSION}/bin/linux/amd64/kubectl"
# curl -LO "https://dl.k8s.io/${K8S_RELEASE_VERSION}/bin/linux/amd64/kubectl.sha256"
# echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
# install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
# kubectl version --client
# rm -f kubectl kubectl.sha256
# DONE

INFO "[*] Install CNI plugin"
mkdir -p "$CNI_DIR"
curl -L "https://gh.con.sh/https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz" | tar -C "$CNI_DIR" -xz
DONE

INFO "[*] Install crictl"
mkdir -p "$BIN_DIR"
curl -L "https://gh.con.sh/https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz" | tar -C $BIN_DIR -xz
DONE

# INFO "[*] Install kubeadm and kubelet"
# cd $BIN_DIR
# curl -L --remote-name-all https://dl.k8s.io/release/${K8S_RELEASE_VERSION}/bin/linux/${ARCH}/{kubeadm,kubelet}
# chmod +x {kubeadm,kubelet}

# curl -sSL "https://raw.gitmirror.com/kubernetes/release/${KUBE_RELEASE_VERSION}/cmd/krel/templates/latest/kubelet/kubelet.service" | sed "s:/usr/bin:${BIN_DIR}:g" | tee /usr/lib/systemd/system/kubelet.service
# mkdir -p /usr/lib/systemd/system/kubelet.service.d
# curl -sSL "https://raw.gitmirror.com/kubernetes/release/${KUBE_RELEASE_VERSION}/cmd/krel/templates/latest/kubeadm/10-kubeadm.conf" | sed "s:/usr/bin:${BIN_DIR}:g" | tee /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
# systemctl enable --now kubelet
# DONE

INFO "[*] Install kubernetes packages"
rpm -Uvh data/kubernetes-$K8S_RELEASE_VERSION.x86_64.rpm
rpm -Uvh data/kubernetes-client-$K8S_RELEASE_VERSION.x86_64.rpm
rpm -Uvh data/kubernetes-help-$K8S_RELEASE_VERSION.x86_64.rpm
rpm -Uvh data/kubernetes-kubeadm-$K8S_RELEASE_VERSION.x86_64.rpm
rpm -Uvh data/kubernetes-kubelet-$K8S_RELEASE_VERSION.x86_64.rpm
rpm -Uvh data/kubernetes-master-$K8S_RELEASE_VERSION.x86_64.rpm
rpm -Uvh data/kubernetes-node-$K8S_RELEASE_VERSION.x86_64.rpm
systemctl enable --now kubelet
DONE

# Reference: https://github.com/cilium/cilium/issues/22933
INFO "[*] Change permissions of /opt/cni"
chown -R $(id -n -u):$(id -n -g) /opt/cni
DONE

INFO "[*] Pull images"
kubeadm config images pull --cri-socket=unix:///var/run/isulad.sock --image-repository=registry.aliyuncs.com/google_containers
DONE

if [ "$ROLE" = "master" ]; then
    INFO "[*] Initiate k8s master"
    kubeadm init --cri-socket=unix:///var/run/isulad.sock --pod-network-cidr=$POD_NET_CIDR --image-repository=registry.aliyuncs.com/google_containers
    mkdir -p $HOME/.kube
    cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config
    DONE
elif [ "$ROLE" = "node" ]; then
    INFO "[*] Perform kubeadm join ..."
    kubeadm join $MASTER_IP --cri-socket=unix:///var/run/isulad.sock \
            --token $TOKEN --discovery-token-ca-cert-hash $CERT_HASH
    DONE
fi

cd ~
