# 一、实践环境准备
## 1. 服务器说明
我们这里使用的是五台centos-7.6的虚拟机，具体信息如下表：

| 系统类型 | IP地址 | 节点角色 | CPU | Memory | Hostname |
| :------: | :--------: | :-------: | :-----: | :---------: | :-----: |
| centos-7.6 | 10.95.0.61 | master |   \>=2    | \>=2G | dev01-61-k8s |
| centos-7.6 | 192.168.8.171 | master |   \>=2    | \>=2G | m2 |
| centos-7.6 | 192.168.8.172 | master |   \>=2    | \>=2G | m3 |
| centos-7.6 | 10.95.0.62 | worker |   \>=2    | \>=2G | dev02-62-k8s |
| centos-7.6 | 10.95.0.63 | worker |   \>=2    | \>=2G | dev03-63-k8s |

## 2. 系统设置（所有节点）
#### 2.1 主机名
主机名必须每个节点都不一样，并且保证所有点之间可以通过hostname互相访问。
```bash
# 查看主机名
$ hostname
# 修改主机名
$ hostnamectl set-hostname <your_hostname>
# 配置host，使所有节点之间可以通过hostname互相访问
$ vi /etc/hosts
# <node-ip> <node-hostname>
```
#### 2.2 安装依赖包
```bash
# 更新yum
$ yum update
# 安装依赖包
$ yum install -y conntrack ipvsadm ipset jq sysstat curl iptables libseccomp
```
#### 2.3 关闭防火墙、swap，重置iptables
```bash
# 关闭防火墙
$ systemctl stop firewalld && systemctl disable firewalld
# 重置iptables
$ iptables -F && iptables -X && iptables -F -t nat && iptables -X -t nat && iptables -P FORWARD ACCEPT
# 关闭swap
$ swapoff -a
$ sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab
# 关闭selinux
$ setenforce 0
# 关闭dnsmasq(否则可能导致docker容器无法解析域名)
$ service dnsmasq stop && systemctl disable dnsmasq
```
#### 2.4 系统参数设置

```bash
# 制作配置文件
$ cat > /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
vm.swappiness=0
vm.overcommit_memory=1
vm.panic_on_oom=0
fs.inotify.max_user_watches=89100
EOF
# 生效文件
$ sysctl -p /etc/sysctl.d/kubernetes.conf
```
## 3. 安装docker（所有节点）
#### 3.1 安装docker

根据kubernetes对docker版本的兼容测试情况，我们选择17.03.1版本
由于近期docker官网速度极慢甚至无法访问，使用yum安装很难成功。我们直接使用rpm方式安装

```bash
# 手动下载rpm包
$ mkdir -p /home/download/docker && cd /home/download/docker
# 从阿里去下载最新的稳定版本包，
$ wget http://mirrors.aliyun.com/docker-ce/linux/centos/7/x86_64/stable/Packages/docker-ce-19.03.13-3.el7.x86_64.rpm
$ wget http://mirrors.aliyun.com/docker-ce/linux/centos/7/x86_64/stable/Packages/docker-ce-cli-19.03.13-3.el7.x86_64.rpm

# 清理原有版本
$ yum remove -y docker* container-selinux
$ sudo yum remove docker \
                  docker-client \
                  docker-ce-client \
                  docker-client-latest \
                  docker-common \
                  docker-latest \
                  docker-latest-logrotate \
                  docker-logrotate \
                  docker-selinux \
                  docker-engine-selinux \
                  docker-engine
$ yum remove docker-ce
$ yum remove docker-ce-cli
# 安装rpm包
$ yum localinstall -y *.rpm
# 开机启动
$ systemctl enable docker
# 设置参数
# 1.查看磁盘挂载
$ df -h
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda2        98G  2.8G   95G   3% /
devtmpfs         63G     0   63G   0% /dev
/dev/sda5      1015G  8.8G 1006G   1% /tol
/dev/sda1       197M  161M   37M  82% /boot
# 2.设置docker启动参数
# - 设置docker数据目录：选择比较大的分区（我这里是根目录就不需要配置了，默认为/var/lib/docker）
# - 设置cgroup driver（默认是cgroupfs，主要目的是与kubelet配置统一，这里也可以不设置后面在kubelet中指定cgroupfs）
$ cat <<EOF > /etc/docker/daemon.json 
{
  "insecure-registries": [
        "10.95.10.60:8082"
  ],
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
  "max-size": "100m",
  "max-file":"1"
  },
  "graph": "/docker/data/path",
  "storage-driver": "overlay2",
  "storage-opts": [
  "overlay2.override_kernel_check=true"
  ]
}
EOF
# 启动docker服务
service docker restart
```

#### 3.2 安装docker-compose

```bash
#移除老旧版本
sudo rm /usr/local/bin/docker-compose
#下载新版本
#国外（慢）
curl -L "https://github.com/docker/compose/releases/download/1.27.4/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
#国内（快）：
curl -L "https://get.daocloud.io/docker/compose/releases/download/1.27.4/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
#设置权限
sudo chmod +x /usr/local/bin/docker-compose
#检查版本
docker-compose version
```

## 4. 安装必要工具（所有节点）

#### 4.1 工具说明
- **kubeadm:**  部署集群用的命令
- **kubelet:** 在集群中每台机器上都要运行的组件，负责管理pod、容器的生命周期
- **kubectl:** 集群管理工具（可选，只要在控制集群的节点上安装即可）

#### 4.2 安装方法

```bash
# 配置yum源（科学上网的同学可以把"mirrors.aliyun.com"替换为"packages.cloud.google.com"）
# https://developer.aliyun.com/mirror/kubernetes?spm=a2c6h.13651102.0.0.3e221b11jlr527
$ cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=http://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=0
repo_gpgcheck=0
gpgkey=http://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg
       http://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF

# 安装工具
# 找到要安装的版本号
$ yum list kubeadm --showduplicates | sort -r

# 安装指定版本（这里用的是1.14.0）
$ yum install -y kubeadm-1.19.3-0 kubelet-1.19.3-0 kubectl-1.19.3-0 --disableexcludes=kubernetes

# 设置kubelet的cgroupdriver（kubelet的cgroupdriver默认为systemd，如果上面没有设置docker的exec-opts为systemd，这里就需要将kubelet的设置为cgroupfs）
$ sed -i "s/cgroup-driver=systemd/cgroup-driver=cgroupfs/g" /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

# 启动kubelet
$ systemctl enable kubelet && systemctl start kubelet

```


## 5. 准备配置文件（任意节点）
#### 5.1 下载配置文件
我这准备了一个项目，专门为大家按照自己的环境生成配置的。它只是帮助大家尽量的减少了机械化的重复工作。它并不会帮你设置系统环境，不会给你安装软件。总之就是会减少你的部署工作量，但不会耽误你对整个系统的认识和把控。
```bash
$ cd ~ && git clone https://gitee.com/pa/kubernetes-ha-kubeadm.git
# 看看git内容
$ ls -l kubernetes-ha-kubeadm
addons/
configs/
scripts/
init.sh
global-configs.properties
```
#### 5.2 文件说明
- **addons**
> kubernetes的插件，比如calico和dashboard。

- **configs**
> 包含了部署集群过程中用到的各种配置文件。

- **scripts**
> 包含部署集群过程中用到的脚本，如keepalive检查脚本。

- **global-configs.properties**
> 全局配置，包含各种易变的配置内容。

- **init.sh**
> 初始化脚本，配置好global-config之后，会自动生成所有配置文件。

#### 5.3 生成配置
这里会根据大家各自的环境生成kubernetes部署过程需要的配置文件。
在每个节点上都生成一遍，把所有配置都生成好，后面会根据节点类型去使用相关的配置。
```bash
# cd到之前下载的git代码目录
$ cd kubernetes-ha-kubeadm

# 编辑属性配置（根据文件注释中的说明填写好每个key-value）
$ vi global-config.properties
-------------------------------------------------------
#kubernetes版本,可使用kubeadm VERSION查看
VERSION=v1.19.3

#POD网段
POD_CIDR=172.22.0.0/16

#master虚拟ip
MASTER_VIP=10.59.0.228

#2个master节点的ip
MASTER_0_IP=10.59.0.61
MASTER_1_IP=10.59.0.62

#2个master节点的hostname
MASTER_0_HOSTNAME=dev01-61-k8s
MASTER_1_HOSTNAME=dev02-62-k8s

#keepalived用到的网卡接口名
VIP_IF=ens192
---------------------------------------------------------

# 生成配置文件，确保执行过程没有异常信息
$ ./init.sh

# 查看生成的配置文件，确保脚本执行成功
$ find target/ -type f
```
> **执行init.sh常见问题：**
> 1. Syntax error: "(" unexpected
> - bash版本过低，运行：bash -version查看版本，如果小于4需要升级
> - 不要使用 sh init.sh的方式运行（sh和bash可能不一样哦）
> 2. global-config.properties文件填写错误，需要重新生成  
> 再执行一次./init.sh即可，不需要手动删除target

```

```

## 6.配置免密码登录

在第一台主机dev01-61-k8s上：

```bash
cd ~
#本操作可以直接回车
ssh-keygen

cd .ssh
cat id_rsa.pub >> authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
#拷贝到其余两台机器上。
ssh-copy-id -i /root/.ssh/id_rsa.pub dev02-62-k8s
ssh-copy-id -i /root/.ssh/id_rsa.pub dev03-63-k8s
```

此时从dev01-61-k8s可以直接ssh到dev02-62-k8s与dev03-63-k8s上。

同理，在每一台机器上执行上面操作，只是最后拷贝时修改非自己的另外两个主机名即可，即密钥对拷，达到相互免密登录。