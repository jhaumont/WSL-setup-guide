#!/bin/bash
set -x

export SOURCE_DIR="/mnt/c/WSL"
export SETUP_DIR="/tmp/setup_wsl"
export USER_DIR="/mnt/c/Users/Dzu-mark2"
export HELM_INSTALL_DIR="/home/jlame/bin"
export VAULT_VERSION="1.3.2"
export HELM_VERSION="v2.16.3"
export K9S_VERSION="0.15.1"
export DOCKER_COMPOSE_VERSION="1.25.4"
export AWS_AUTHENTICATOR_VERSION="0.5.0"
export KREW_VERSION="v0.3.4"
export YQ_VERSION="3.1.1"

# setup
mkdir -p ${SETUP_DIR} ~/bin ~/.helm/plugins ~/.docker
cd ${SETUP_DIR}
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

# Copy files
# setup custome profile
cp ${SOURCE_DIR}/.profile_custom ~
cp ${SOURCE_DIR}/.bash_aliases ~
# fix vi
cp ${SOURCE_DIR}/.exrc ~
# import script for ssh agent
cp ${SOURCE_DIR}/start-ssh-agent ~/bin
# docker config (if you want to copy one)
#cp ${SOURCE_DIR}/config.json ~/.docker
# ansible TODO : à revoir sur les droits positionnés ! faire un chmod 640 (if you want to copy this one)
#cp -R ${SOURCE_DIR}/.ansible ~
# copy wsl.conf
sudo cp ${SOURCE_DIR}/wsl.conf /etc
sudo chmod 644 /etc/wsl.conf

# Add custom profile sourcing to .profile
echo '. ~/.profile_custom' >> ~/.profile

# update ubuntu
sudo apt update -y
sudo apt full-upgrade -y

# Package installation (add a desciption for each) first part
sudo apt install -y bash-completion man python3 python-pip python3-pip python3-venv ssh netcat-openbsd sl pandoc jq apt-transport-https curl git pkg-config ca-certificates gnupg2 software-properties-common wget

# Prepare repo
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee -a /etc/apt/sources.list.d/kubernetes.list
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

# Package installation (add a desciption for each) second part
sudo apt update
sudo apt install -y kubectl docker-ce
sudo usermod -aG docker ${LOGNAME}
sudo ln -s /usr/bin/kubectl /usr/local/bin/kubectl

# install docker-compose
sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod 755 /usr/local/bin/docker-compose

# Install helm & tiller
curl -LO https://git.io/get_helm.sh
chmod 700 get_helm.sh
${SETUP_DIR}/get_helm.sh --version ${HELM_VERSION} --no-sudo
helm plugin install https://github.com/nico-ulbricht/helm-multivalues
sudo ln -s ~/bin/helm /usr/local/bin/helm
sudo ln -s ~/bin/tiller /usr/local/bin/tiller

# Installing vault
curl -o ${SETUP_DIR}/vault_${VAULT_VERSION}.zip -s https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip 
unzip ${SETUP_DIR}/vault_${VAULT_VERSION}.zip -d ~/bin

# Install terraform switch
# possible de tester avec celui là : https://github.com/tfutils/tfenv
curl -LO https://raw.githubusercontent.com/warrensbox/terraform-switcher/release/install.sh
chmod 700 install.sh
${SETUP_DIR}/install.sh -b ${HELM_INSTALL_DIR}

# Install kubectx
git clone https://github.com/ahmetb/kubectx.git ~/.kubectx
COMPDIR=$(pkg-config --variable=completionsdir bash-completion)
sudo ln -sf ~/.kubectx/completion/kubens.bash $COMPDIR/kubens
sudo ln -sf ~/.kubectx/completion/kubectx.bash $COMPDIR/kubectx

# Install kubetail
git clone https://github.com/johanhaleby/kubetail ~/.kubetail
sudo ln -sf ~/.kubetail/completion/kubetail.bash $COMPDIR/kubetail

# Install k9s
curl -LO https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_${K9S_VERSION}_Linux_x86_64.tar.gz
tar xvfz k9s_${K9S_VERSION}_Linux_x86_64.tar.gz
cp k9s ~/bin

# Install yq
curl -L "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" -o ~/bin/yq
chmod 750 ~/bin/yq

# define python3 as default python
sudo update-alternatives --install /usr/bin/python python /usr/bin/python2.7 1
sudo update-alternatives --install /usr/bin/python python /usr/bin/python3.8 2

# TODO : move to requirements file
# modules python 
# pip install virtualenv virtualenvwrapper pywinrm ansible awslogs azure-cli
# pip3 install awscli --upgrade --user
# curl -L https://aka.ms/InstallAzureCli | bash

# TODO : remove this one ?
# Install aws auhtentificator
wget -O ~/bin/aws-iam-authenticator https://github.com/kubernetes-sigs/aws-iam-authenticator/releases/download/v${AWS_AUTHENTICATOR_VERSION}/aws-iam-authenticator_${AWS_AUTHENTICATOR_VERSION}_linux_amd64
chmod 750 ~/bin/aws-iam-authenticator

# Install krew
curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/download/${KREW_VERSION}/krew.{tar.gz,yaml}"
tar zxvf krew.tar.gz
./krew-"$(uname | tr '[:upper:]' '[:lower:]')_amd64" install \
    --manifest=krew.yaml --archive=krew.tar.gz

#sym link to share conf with windows (decomment if needed)
ln -s ${USER_DIR}/.ssh ~/.ssh
ln -s ${USER_DIR}/.aws ~/.aws
ln -s ${USER_DIR}/.kube ~/.kube

# clean up setup dir
rm -rf ${SETUP_DIR}

echo "before using wsl, please do this 'wsl.exe -s Ubuntu' in cmd prompt and create scheduled task (see https://github.com/bahamas10/windows-bash-ssh-agent)"
echo "To finalize docker engine access from wsl, finalize docker configuration on windows side based on this https://nickjanetakis.com/blog/setting-up-docker-for-windows-and-wsl-to-work-flawlessly"
echo "install talend helm plugin manually https://github.com/Talend/helm-charts/blob/master/utils/talend-helm-plugin/README.md"
