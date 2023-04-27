#!/bin/bash
Red='\033[0;31m'
Yellow='\033[0;33m'
Green='\033[0;32m'
NC='\033[0m'

function copyConfig(){
  mkdir -p $HOME/.kube
  sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
}
#set -x

KUBE_VERSION="1.26.1"
KUBE_PACKAGE_VERSION="$KUBE_VERSION-0"

currentOS=$(grep "^PRETTY_NAME=" /etc/os-release | awk -F'=' '{print $2}')
echo -e "Starting installation on ${Yellow} $currentOS ${NC}"

# Check if firewalld is active and disable it
if systemctl is-active --quiet firewalld.service; then
    echo "Firewalld service is active. Disabling..."
    sudo systemctl stop firewalld.service
    sudo systemctl disable firewalld.service
    echo "Firewalld service has been disabled."
else
    echo "Firewalld service is not active."
fi

# Disable swap
echo "[TASK 0] Disable swap"
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Setup Kernel modules and sysctl
echo "[TASK 1] Setup Kernel modules and sysctl"
cat <<EOF | tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

tee /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system

# Install required packages
echo "[TASK 2] Installing packages"
yum install -y curl gnupg2 yum-utils device-mapper-persistent-data lvm2
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
yum install -y docker-ce docker-ce-cli containerd.io

# Enable docker service
echo "[TASK 3] install Docker and containerd"
systemctl start docker
systemctl enable docker

# Install containerd
yum install -y containerd.io
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null 2>&1
sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# Add Kubernetes repo
cat <<EOF >/etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg
        https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF

# Install k8s packages
sudo yum install -y kubelet-$KUBE_PACKAGE_VERSION kubeadm-$KUBE_PACKAGE_VERSION kubectl-$KUBE_PACKAGE_VERSION
sudo systemctl enable kubelet
sudo systemctl start kubelet

# Checking if SELINUX is set to Permissive
SELINUX=$(grep "^SELINUX=" /etc/selinux/config | awk -F'=' '{print $2}')
echo -e "SELINUX is curently set to ${Yellow}$SELINUX${NC}.\n"
if [ "$SELINUX" != "permissive" ]; then
  sudo sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
  echo -e "In order to apply the change ${Yellow}reboot${NC} is needed!\n"
  echo -e "After the reboot, please test by running getenforce . It should return '${Yellow}Permissive${NC}'\n"
fi

# init cluster
myhost=$(hostname -i)
echo -e "Do you want to initiate the Cluster? : ( y / n ) "
read node0
if [ "$node0" == "y" ];then
		echo -e "Are you running the Cluster on ${Green}single${NC} node? ( y / n )"
		read node1
	if [ "$node1" == "y" ];then
		echo "Running ..."
		echo "kubeadm init --apiserver-advertise-address=$myhost --control-plane-endpoint=$myhost --apiserver-cert-extra-sans=$myhost --pod-network-cidr=172.16.0.0/16"
		sudo kubeadm init --apiserver-advertise-address=$myhost --control-plane-endpoint=$myhost --apiserver-cert-extra-sans=$myhost --pod-network-cidr=172.16.0.0/16
		copyConfig # copy config 
		echo "Tainting node"		
		kubectl taint nodes --all node-role.kubernetes.io/control-plane-
	else 
		echo -e "Running ..."
		echo "kubeadm init --apiserver-advertise-address=$myhost --control-plane-endpoint=$myhost --apiserver-cert-extra-sans=$myhost --pod-network-cidr=172.16.0.0/16 --upload-certs"
		sudo kubeadm init --apiserver-advertise-address=$myhost --control-plane-endpoint=$myhost --apiserver-cert-extra-sans=$myhost --pod-network-cidr=172.16.0.0/16 --upload-certs
		copyConfig # copy config
	fi
	# installing CALICO
	curl https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/calico.yaml -O
	kubectl apply -f calico.yaml
	
else
	echo -e "${Green} Deployment ready. ${Red} Dont worry, kubelet will start working once you have initated the Cluster!!! ${NC}\n"
fi




# Hold the k8s packages
#yum versionlock add kubelet kubeadm kubectl

# for CALICO use:
# curl https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/calico.yaml -O
# kubectl apply -f calico.yaml


# if you are running single node
# do not forget to untaint it
# kubectl taint nodes --all node-role.kubernetes.io/control-plane-

sudo setenforce Permissive # set to permissive until the next reboot