# Kubernetes Deploy

这是一个简易的用于部署[Kubernetes](https://kubernetes.io)以及相关网络组件的脚本集合，能够自动拉取当前最新版本的组件，并自动化的部署一个Kubernetes集群。

支持的Container Runtime：

- [containerd](https://github.com/containerd/containerd)
- [iSulad](https://gitee.com/openeuler/iSulad)

支持部署的CNI插件：

- [Calico](https://www.tigera.io/project-calico/)
- [Cilium](https://www.cilium.io/)

测试部署系统：[OpenEuler](https://www.openeuler.org) 22.03 LTS

## 文件结构说明

```shell
├── data
│   ├── daemon.json
│   ├── rpm.tar.gz.00
│   ├── rpm.tar.gz.01
│   ├── rpm.tar.gz.02
│   ├── rpm.tar.gz.03
│   ├── rpm.tar.gz.04
│   ├── rpm.tar.gz.05
│   ├── rpm.tar.gz.06
│   ├── rpm.tar.gz.07
│   ├── rpm.tar.gz.08
│   └── rpm.tar.gz.09
├── init-calico-master.sh
├── init-cilium-master.sh
├── init-k8s-containerd.sh
├── init-k8s-isulad.sh
└── README.md
```

- `init-k8s-isulad.sh`: 自动初始化Kubernetes脚本，以iSulad为容器运行时
- `init-k8s-isulad.sh`: 自动初始化Kubernetes脚本，以containerd为容器运行时
- `init-calico-master.sh`: 用于在master节点Kubernetes初始化完成之后，部署Calico CNI组件
- `init-cilium-master.sh`: 用于在master节点Kubernetes初始化完成之后，部署Cilium CNI组件（Cilium的安装需要在Kubernetes集群已安装CNI插件的情况下才能运行，如Calico、Flannel）
- `data/daemon.json`: iSulad的初始配置文件
- `data/rpm.tar.gz.*`: 用于iSulad运行时下Kubernetes部署所需要的RPM软件包（iSulad、kubernetes、kubernetes-client、kubernetes-help、kubernetes-kubeadm、kubernetes-kubelet、kubernetes-master、kubernetes-node）

## 部署说明

### Kubernetes部署脚本的使用

```
Usage: ./init-k8s-isulad.sh master|node [--build] [--master-ip <ip>] [--token <token>] [--hash <hash>]
    --build     Build iSulad intead of using existing RPM
    --master-ip IP:PORT of master node, example: 127.0.0.1:6443
    --token     Value of --token in kubeadm join
    --hash      Value of --ca-cert-hash in kubeadm join, example: sha256:......
```

两个自动化部署Kubernetes的脚本均支持master节点与node节点的自动部署。对于iSulad的部署需要提供`--build`参数用于指明是现场编译iSulad还是使用编译好的RPM包，containerd的部署则不需要此参数。对于node节点的部署需要提供`kubeadm join`命令的参数用于自动加入集群，对应参数可以使用`kubeadm token create --print-join-command`获取。

### CNI组件的安装

在Kubernetes部署完毕之后，使用对应的CNI组件部署脚本可以自动化部署对应的CNI组件，为容器集群提供网络功能。

#### Calico

在master节点上直接执行`init-calico-master.sh`即可。脚本内容参照[官方文档](https://docs.tigera.io/calico/latest/getting-started/kubernetes/quickstart)编写。

#### Cilium

在master节点上直接执行`init-cilium-master.sh`即可。脚本内容参照[官方文档](https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default)编写。

注意：在安装Cilium之前请确保当前Kubernetes集群已有CNI组件，如可按照前面说明先安装Calico，再安装Cilium。

### 容器运行时配置文件改动

#### iSulad

- `pod-sandbox-image`更换阿里云源
    ```json
    "pod-sandbox-image": "registry.aliyuncs.com/google_containers/pause:3.9",
    ```
- 设置网络插件为CNI，添加CNI的组件目录
    ```json
    "network-plugin": "cni",
    "cni-bin-dir": "/opt/cni/bin",
    "cni-conf-dir": "/etc/cni/net.d",
    ```
- 启用CRI V1（默认不启用），Kubernetes默认支持的是CRI V1，不启用会报错
    ```json
    "enable-cri-v1": true,
    ```

#### containerd

```shell
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sed -i 's/disabled_plugins/# disabled_plugins/g' /etc/containerd/config.toml
sed -i 's#registry.k8s.io#registry.aliyuncs.com/google_containers#g' /etc/containerd/config.toml
```

### 一些参考Issue与PR

- <https://github.com/cilium/cilium/issues/22933>
- <https://gitee.com/openeuler/iSulad/issues/I46FKB>
- <https://gitee.com/openeuler/iSulad/pulls/2435>
- <https://gitee.com/openeuler/iSulad/issues/I9IRGZ>
- <https://github.com/kubernetes/enhancements/issues/4006>
- <https://github.com/containerd/containerd/issues/4581>
