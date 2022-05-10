#!/usr/bin/env bash

set -o pipefail
set -o nounset
set -o errexit
IFS=$'\n\t'

TEMPLATE_DIR=${TEMPLATE_DIR:-/tmp/worker}

################################################################################
### Validate Required Arguments ################################################
################################################################################
validate_env_set() {
    (
        set +o nounset

        if [ -z "${!1}" ]; then
            echo "Packer variable '$1' was not set. Aborting"
            exit 1
        fi
    )
}

validate_env_set BINARY_BUCKET_NAME
validate_env_set BINARY_BUCKET_REGION
validate_env_set CNI_PLUGIN_VERSION
validate_env_set KUBERNETES_VERSION
validate_env_set KUBERNETES_BUILD_DATE
validate_env_set PULL_CNI_FROM_GITHUB

################################################################################
### Machine Architecture #######################################################
################################################################################

MACHINE=$(uname -m)
if [ "$MACHINE" == "x86_64" ]; then
    ARCH="amd64"
elif [ "$MACHINE" == "aarch64" ]; then
    ARCH="arm64"
else
    echo "Unknown machine architecture '$MACHINE'" >&2
    exit 1
fi


################################################################################
### iptables ###################################################################
################################################################################
sudo mkdir -p /etc/eks
sudo mv $TEMPLATE_DIR/iptables-restore.service /etc/eks/iptables-restore.service


################################################################################
### Logrotate ##################################################################
################################################################################

# kubelet uses journald which has built-in rotation and capped size.
# See man 5 journald.conf
sudo mv $TEMPLATE_DIR/logrotate-kube-proxy /etc/logrotate.d/kube-proxy
sudo chown root:root /etc/logrotate.d/kube-proxy
sudo mkdir -p /var/log/journal

################################################################################
### Kubernetes #################################################################
################################################################################

sudo mkdir -p /etc/kubernetes/manifests
sudo mkdir -p /var/lib/kubernetes
sudo mkdir -p /var/lib/kubelet
sudo mkdir -p /opt/cni/bin

echo "Downloading binaries from: s3://$BINARY_BUCKET_NAME"
S3_DOMAIN="amazonaws.com"
if [ "$BINARY_BUCKET_REGION" = "cn-north-1" ] || [ "$BINARY_BUCKET_REGION" = "cn-northwest-1" ]; then
    S3_DOMAIN="amazonaws.com.cn"
elif [ "$BINARY_BUCKET_REGION" = "us-iso-east-1" ]; then
    S3_DOMAIN="c2s.ic.gov"
elif [ "$BINARY_BUCKET_REGION" = "us-isob-east-1" ]; then
    S3_DOMAIN="sc2s.sgov.gov"
fi
S3_URL_BASE="https://$BINARY_BUCKET_NAME.s3.$BINARY_BUCKET_REGION.$S3_DOMAIN/$KUBERNETES_VERSION/$KUBERNETES_BUILD_DATE/bin/linux/$ARCH"
S3_PATH="s3://$BINARY_BUCKET_NAME/$KUBERNETES_VERSION/$KUBERNETES_BUILD_DATE/bin/linux/$ARCH"

BINARIES=(
    kubelet
    aws-iam-authenticator
)
for binary in ${BINARIES[*]} ; do
    sudo wget $S3_URL_BASE/$binary
    sudo wget $S3_URL_BASE/$binary.sha256
    sudo sha256sum -c $binary.sha256
    sudo chmod +x $binary
    sudo mv $binary /usr/bin/
done

# Since CNI 0.7.0, all releases are done in the plugins repo.
CNI_PLUGIN_FILENAME="cni-plugins-linux-${ARCH}-${CNI_PLUGIN_VERSION}"

if [ "$PULL_CNI_FROM_GITHUB" = "true" ]; then
    echo "Downloading CNI plugins from Github"
    wget "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/${CNI_PLUGIN_FILENAME}.tgz"
    wget "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/${CNI_PLUGIN_FILENAME}.tgz.sha512"
    sudo sha512sum -c "${CNI_PLUGIN_FILENAME}.tgz.sha512"
    rm "${CNI_PLUGIN_FILENAME}.tgz.sha512"
else
    sudo wget "$S3_URL_BASE/${CNI_PLUGIN_FILENAME}.tgz"
    sudo wget "$S3_URL_BASE/${CNI_PLUGIN_FILENAME}.tgz.sha256"
    sudo sha256sum -c "${CNI_PLUGIN_FILENAME}.tgz.sha256"
fi
sudo tar -xvf "${CNI_PLUGIN_FILENAME}.tgz" -C /opt/cni/bin
rm "${CNI_PLUGIN_FILENAME}.tgz"

sudo rm ./*.sha256

sudo mkdir -p /etc/kubernetes/kubelet
sudo mkdir -p /etc/systemd/system/kubelet.service.d
sudo mv $TEMPLATE_DIR/kubelet-kubeconfig /var/lib/kubelet/kubeconfig
sudo chown root:root /var/lib/kubelet/kubeconfig

# Inject CSIServiceAccountToken feature gate to kubelet config if kubernetes version starts with 1.20.
# This is only injected for 1.20 since CSIServiceAccountToken will be moved to beta starting 1.21.
if [[ $KUBERNETES_VERSION == "1.20"* ]]; then
    KUBELET_CONFIG_WITH_CSI_SERVICE_ACCOUNT_TOKEN_ENABLED=$(cat $TEMPLATE_DIR/kubelet-config.json | jq '.featureGates += {CSIServiceAccountToken: true}')
    echo $KUBELET_CONFIG_WITH_CSI_SERVICE_ACCOUNT_TOKEN_ENABLED > $TEMPLATE_DIR/kubelet-config.json
fi

if [[ $KUBERNETES_VERSION == "1.22"* ]]; then
    # enable CredentialProviders feature flags in kubelet service file
    IMAGE_CREDENTIAL_PROVIDER_FLAGS='\\\n    --image-credential-provider-config /etc/eks/ecr-credential-provider/ecr-credential-provider-config \\\n    --image-credential-provider-bin-dir /etc/eks/ecr-credential-provider'
    sudo sed -i s,"aws","aws $IMAGE_CREDENTIAL_PROVIDER_FLAGS", $TEMPLATE_DIR/kubelet.service
    # enable KubeletCredentialProviders features in kubelet configuration
    KUBELET_CREDENTIAL_PROVIDERS_FEATURES=$(cat $TEMPLATE_DIR/kubelet-config.json | jq '.featureGates += {KubeletCredentialProviders: true}')
    printf "%s" "$KUBELET_CREDENTIAL_PROVIDERS_FEATURES" > "$TEMPLATE_DIR/kubelet-config.json"
fi

sudo mv $TEMPLATE_DIR/kubelet.service /etc/systemd/system/kubelet.service
sudo chown root:root /etc/systemd/system/kubelet.service
sudo mv $TEMPLATE_DIR/kubelet-config.json /etc/kubernetes/kubelet/kubelet-config.json
sudo chown root:root /etc/kubernetes/kubelet/kubelet-config.json


sudo systemctl daemon-reload
# Disable the kubelet until the proper dropins have been configured
sudo systemctl disable kubelet

################################################################################
### EKS ########################################################################
################################################################################

sudo mkdir -p /etc/eks
sudo mv $TEMPLATE_DIR/eni-max-pods.txt /etc/eks/eni-max-pods.txt
sudo mv $TEMPLATE_DIR/bootstrap.sh /etc/eks/bootstrap.sh
sudo chmod +x /etc/eks/bootstrap.sh
sudo mv $TEMPLATE_DIR/max-pods-calculator.sh /etc/eks/max-pods-calculator.sh
sudo chmod +x /etc/eks/max-pods-calculator.sh

SONOBUOY_E2E_REGISTRY="${SONOBUOY_E2E_REGISTRY:-}"
if [[ -n "$SONOBUOY_E2E_REGISTRY" ]]; then
    sudo mv $TEMPLATE_DIR/sonobuoy-e2e-registry-config /etc/eks/sonobuoy-e2e-registry-config
    sudo sed -i s,SONOBUOY_E2E_REGISTRY,$SONOBUOY_E2E_REGISTRY,g /etc/eks/sonobuoy-e2e-registry-config
fi

################################################################################
### ECR CREDENTIAL PROVIDER ####################################################
################################################################################
if [[ $KUBERNETES_VERSION == "1.22"* ]]; then
    ECR_BINARY="ecr-credential-provider"
    sudo wget "$S3_URL_BASE/$ECR_BINARY"
    sudo chmod +x $ECR_BINARY
    sudo mkdir -p /etc/eks/ecr-credential-provider
    sudo mv $ECR_BINARY /etc/eks/ecr-credential-provider

    # copying credential provider config file to eks folder
    sudo mv $TEMPLATE_DIR/ecr-credential-provider-config /etc/eks/ecr-credential-provider/ecr-credential-provider-config
fi

################################################################################
### AMI Metadata ###############################################################
################################################################################

BASE_AMI_ID=$(curl -s  http://169.254.169.254/latest/meta-data/ami-id)
cat <<EOF > /tmp/release
BASE_AMI_ID="$BASE_AMI_ID"
BUILD_TIME="$(date)"
BUILD_KERNEL="$(uname -r)"
ARCH="$(uname -m)"
EOF
sudo mv /tmp/release /etc/eks/release
sudo chown -R root:root /etc/eks

################################################################################
### Stuff required by "protectKernelDefaults=true" #############################
################################################################################

#cat <<EOF | sudo tee -a /etc/sysctl.d/99-amazon.conf
#vm.overcommit_memory=1
#kernel.panic=10
#kernel.panic_on_oops=1
#EOF

################################################################################
### Setting up sysctl properties ###############################################
################################################################################

#echo fs.inotify.max_user_watches=524288 | sudo tee -a /etc/sysctl.conf
#echo fs.inotify.max_user_instances=8192 | sudo tee -a /etc/sysctl.conf
#echo vm.max_map_count=524288 | sudo tee -a /etc/sysctl.conf


################################################################################
### Cleanup ####################################################################
################################################################################

sudo touch /etc/machine-id
touch /tmp/eks-install-done
