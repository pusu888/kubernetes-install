

# 二. 搭建高可用集群

## 1. 部署keepalived - apiserver高可用（任选两个master节点）
#### 1.1 安装keepalived
```bash
# 在两个主节点上安装keepalived（一主一备）
$ yum install -y keepalived
```
#### 1.2 创建keepalived配置文件
```bash
# 创建目录
$ ssh <user>@<master-ip> "mkdir -p /etc/keepalived"
$ ssh <user>@<backup-ip> "mkdir -p /etc/keepalived"

# 分发配置文件
$ scp target/configs/keepalived-master.conf <user>@<master-ip>:/etc/keepalived/keepalived.conf
$ scp target/configs/keepalived-backup.conf <user>@<backup-ip>:/etc/keepalived/keepalived.conf

# 分发监测脚本
$ scp target/scripts/check-apiserver.sh <user>@<master-ip>:/etc/keepalived/
$ scp target/scripts/check-apiserver.sh <user>@<backup-ip>:/etc/keepalived/
```

#### 1.3 启动keepalived
```bash
# 分别在master和backup上启动服务
$ systemctl enable keepalived && service keepalived start

# 检查状态
$ service keepalived status

# 查看日志
$ journalctl -f -u keepalived

# 查看虚拟ip
$ ip a
```

## 2. 部署第一个主节点
```bash
# 准备配置文件
$ scp target/configs/kubeadm-config.yaml <user>@<node-ip>:~
```

#### 2.1 准备配置文件

kubeadm-config.yaml：

```yaml
apiVersion: kubeadm.k8s.io/v1beta2
kind: ClusterConfiguration
kubernetesVersion: v1.19.0
imageRepository: registry.aliyuncs.com/google_containers
clusterName: kubernetes
etcd:
  local:
    extraArgs:
      listen-client-urls: "https://127.0.0.1:2379,https://10.95.10.61:2379"
      advertise-client-urls: "https://10.95.10.61:2379"
      listen-peer-urls: "https://10.95.10.61:2380"
      initial-advertise-peer-urls: "https://10.95.10.61:2380"
      initial-cluster: "dev01-61-k8s=https://10.95.10.61:2380"
    serverCertSANs:
      - dev01-61-k8s
      - 10.95.10.61
    peerCertSANs:
      - dev01-61-k8s
      - 10.95.10.61
networking:
    podSubnet: 10.244.0.0/16
```

可以使用如下命令获取默认的配置，然后修改：

```shell
$ kubeadm config print init-defaults
```



#### 2.2 提前下载镜像

我们使用registry.aliyuncs.com/google_containers镜像库，默认是k8s.gcr.io,国内无法下载。

```shell
$ kubeadm config images pull --config=kubeadm-config.yaml
```

#### 2.3 kubeadm init 初始化第一个节点

```shell
# ssh到第一个主节点，执行kubeadm初始化系统（注意保存最后打印的加入集群的命令）
#$ kubeadm init --config=kubeadm-config.yaml --experimental-upload-certs
$ kubeadm init --config=kubeadm-config.yaml

# **备份init打印的join命令**
```

kubeadm init最后打印出来的内容：

```
......

Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

You should now deploy a pod network to the cluster.
Run "kubectl apply -f [podnetwork].yaml" with one of the options listed at:
  https://kubernetes.io/docs/concepts/cluster-administration/addons/

Then you can join any number of worker nodes by running the following on each as root:

kubeadm join 10.95.10.61:6443 --token l8ymoe.8wh0u436j6qqjled \
    --discovery-token-ca-cert-hash sha256:42d2235d05d1f1ea271c4106290f2b62b57c4b73037c9611fff76ea0e921e392 
```

#### 2.4 配置kubectl

```shell
# copy kubectl配置（根据上一步提示）
$ mkdir -p ~/.kube
$ cp -i /etc/kubernetes/admin.conf ~/.kube/config
$ sudo chown $(id -u):$(id -g) ~/.kube/config
# 测试一下kubectl
$ kubectl get pods --all-namespaces
```

#### 2.5 安装网络插件-flanel

```shell
$ wget https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
#如无法下载，可使用本地root@10.95.10.61:/home/download/docker/k8s/kube-flannel.yaml
```

修改kube-flannel.yml文件：

确保能够访问到quay.io这个registery。

如果Pod镜像下载失败，可以改成这个镜像地址：lizhenliang/flannel:v0.11.0-amd64，注意有两个地方需要修改这个镜像。

还要修改如下地方：

```
net-conf.json: |
    {
      "Network": "10.244.0.0/16",  #这个地方需要与上面kubeadmin-config中的podSubnet: 10.244.0.0/16相同。
      "Backend": {
        "Type": "vxlan"
      }
    }
```

然后创建：

```shell
$ kubectl apply -f  ./kube-flannel.yml
#检查pod运行情况
$ kubectl get pods -n kube-system -o wide
```

检查结果，此时coredns的pod应该运行正常

#### 2.6 允许master节点也可以跑pod

即当作node跑pod:

```shell
$ kubectl taint nodes --all node-role.kubernetes.io/master-
```



## 3. copy相关配置

#### 3.1 copy证书和密钥

其它节点需要的证书文件列表：

```
/etc/kubernetes/pki/ca.crt
/etc/kubernetes/pki/ca.key
/etc/kubernetes/pki/sa.key
/etc/kubernetes/pki/sa.pub
/etc/kubernetes/pki/front-proxy-ca.crt
/etc/kubernetes/pki/front-proxy-ca.key
/etc/kubernetes/pki/etcd/ca.crt
/etc/kubernetes/pki/etcd/ca.key
/etc/kubernetes/admin.conf
```

copy-config.sh

```shell
#/bin/bash
USER=root
CONTROL_PLANE_IPS="dev02-62-k8s dev03-63-k8s"
for host in ${CONTROL_PLANE_IPS}; do
    ssh "${USER}"@$host "mkdir -p /etc/kubernetes/pki/etcd"
    scp /etc/kubernetes/pki/ca.* "${USER}"@$host:/etc/kubernetes/pki/
    scp /etc/kubernetes/pki/sa.* "${USER}"@$host:/etc/kubernetes/pki/
    scp /etc/kubernetes/pki/front-proxy-ca.* "${USER}"@$host:/etc/kubernetes/pki/
    scp /etc/kubernetes/pki/etcd/ca.* "${USER}"@$host:/etc/kubernetes/pki/etcd/
    scp /etc/kubernetes/admin.conf "${USER}"@$host:/etc/kubernetes/
done
```



```shell
#在第一个master节点上，拷贝文件到其它master节点
[root@dev01-61-k8s pki]# scp -r /etc/kubernetes/pki dev02-62-k8s:/etc/kubernetes/
[root@dev01-61-k8s pki]# scp /etc/kubernetes/admin.conf dev02-62-k8s:/etc/kubernetes/
```

在另一个master节点上

```shell

```

#### 3.2 copy kubeadm-config

```shell
#copy kubeadm-config.yml到其余的master节点

$ scp /home/download/docker/k8s/target/configs/kubeadm-config.yaml dev02-62-k8s:/home/download/docker/k8s
```

## 4. 部署kubernetes-dashboard

#### 4.1 下载kubernetes-dashboard.yaml文件

wget https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-beta8/aio/deploy/recommended.yaml 

重命名为：kubernetes-dashboard.yaml

或者直接使用root@10.95.10.61:/home/download/docker/k8s/kubernetes-dashboard.yaml

#### 4.2配置NodePort

在kubernetes-dashboard.yaml中的kubernetes-dashboard Service段，增加NodePort配置，便于在外面以node ip进行访问

```shell
$ vi kubernetes-dashboard.yaml

kind: Service
apiVersion: v1
metadata:
  labels:
    k8s-app: kubernetes-dashboard
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
spec:
  type: NodePort  #增加
  ports:
    - port: 443
      targetPort: 8443
      nodePort: 30001  #增加
  selector:
    k8s-app: kubernetes-dashboard
```

#### 4.3 创建证书

为kubernetes-dashboard创建证书，才可能用非firefox浏览器访问

```shell
#创建自签名CA
$ mkdir /home/download/docker/k8s/ssl && cd /home/download/docker/k8s/ssl
$ openssl genrsa -out ca.key 2048
$ openssl req -new -x509 -key ca.key -out ca.crt -days 3650 -subj "/C=CN/ST=HB/L=WH/O=DM/OU=YPT/CN=CA" 
$ openssl x509 -in ca.crt -noout -text
#签发Dashboard证书
$ openssl genrsa -out dashboard.key 2048
$ openssl req -new -sha256 -key dashboard.key -out dashboard.csr -subj "/C=CN/ST=HB/L=WH/O=DM/OU=YPT/CN=10.95.10.61"
$ vi dashboard.cnf
extensions = san
[san]
keyUsage = digitalSignature
extendedKeyUsage = clientAuth,serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = IP:10.95.10.61,DNS:localhost

$ openssl x509 -req -sha256 -days 3650 -in dashboard.csr -out dashboard.crt -CA ca.crt -CAkey ca.key -CAcreateserial -extfile dashboard.cnf
$ openssl x509 -in dashboard.crt -noout -text
#挂载证书到kubernetes-dashboard
$ cd ../
#如果之前有安装过
$ kubectl delete -f kubernetes-dashboard.yaml
$ kubectl create namespace kubernetes-dashboard  #namespace与kubernetes-dashboard.yaml中的一致
$ kubectl create secret generic kubernetes-dashboard-certs --from-file="./dashboard.crt,./dashboard.key" -n kubernetes-dashboard
#修改kubernetes-dashboard.yaml的配置
$ vi kubernetes-dashboard.yaml
args:
            - --auto-generate-certificates
            - --namespace=kubernetes-dashboard
            - --tls-key-file=dashboard.key   #新增
            - --tls-cert-file=dashboard.crt  #新增
```

#### 4.4 创建kubernetes-dashboard及帐号

```shell
#再次创建dashboard
$ kubectl apply -f kubernetes-dashboard.yaml

#创建service account
$ kubectl create serviceaccount dashboard-admin -n kubernetes-dashboard
#把serviceaccount绑定在cluster-admin，授权serviceaccount用户具有整个集群的访问管理权限
$ kubectl create clusterrolebinding dashboard-admin --clusterrole=cluster-admin --serviceaccount=kubernetes-dashboard:dashboard-admin
#获取token
$ kubectl describe secrets -n kubernetes-dashboard $(kubectl -n kubernetes-dashboard get secret | awk '/dashboard-admin/{print $1}')

#此时，即可以用非firefox浏览器访问，并填入token进行访问了
```



## 4. 部署第二个主节点

#### 4.1 删除多余的配置文件

```shell
#删除多余的文件
[root@dev02-62-k8s pki]# cd /etc/kubernetes/pki
[root@dev02-62-k8s pki]# rm -fr apiserver*
[root@dev02-62-k8s pki]# rm -fr front-proxy-client.*
[root@dev02-62-k8s pki]# rm -fr etcd/healthcheck-client.*
[root@dev02-62-k8s pki]# rm -fr etcd/peer.*
[root@dev02-62-k8s pki]# rm -fr etcd/server.* 
```

留下以下必须的配置文件

```
/etc/kubernetes/pki/ca.crt
/etc/kubernetes/pki/ca.key
/etc/kubernetes/pki/sa.key
/etc/kubernetes/pki/sa.pub
/etc/kubernetes/pki/front-proxy-ca.crt
/etc/kubernetes/pki/front-proxy-ca.key
/etc/kubernetes/pki/etcd/ca.crt
/etc/kubernetes/pki/etcd/ca.key
/etc/kubernetes/admin.conf
```

4.2 准备初始化脚本init-master-second.sh



## 4. 部署网络插件 - calico

**该地址列出可选网络插件**
 https://kubernetes.io/docs/concepts/cluster-administration/addons/

  

**参考kubeneters权威指南，使用weave插件，使用如下命令配置网络插件**
 kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version|base64|tr -d '\n')"







我们使用calico官方的安装方式来部署。

```bash
# 创建目录（在配置了kubectl的节点上执行）
$ mkdir -p /etc/kubernetes/addons

# 上传calico配置到配置好kubectl的节点（一个节点即可）
$ scp target/addons/calico* <user>@<node-ip>:/etc/kubernetes/addons/

# 部署calico
$ kubectl apply -f /etc/kubernetes/addons/calico-rbac-kdd.yaml
$ kubectl apply -f /etc/kubernetes/addons/calico.yaml

# 查看状态
$ kubectl get pods -n kube-system
```
## 4. 加入其它master节点
```bash
# 使用之前保存的join命令加入集群
$ kubeadm join ...

# 耐心等待一会，并观察日志
$ journalctl -f

# 查看集群状态
# 1.查看节点
$ kubectl get nodes
# 2.查看pods
$ kubectl get pods --all-namespaces
```

## 5. 加入worker节点
```bash
# 使用之前保存的join命令加入集群
$ kubeadm join ...

# 耐心等待一会，并观察日志
$ journalctl -f

# 查看节点
$ kubectl get nodes
```
