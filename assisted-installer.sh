#!/bin/bash
echo "### Setting Variables..."
export OFFLINE_ACCESS_TOKEN=$(cat ~/ocm-token)
export ASSISTED_SERVICE_API="api.openshift.com"
export CLUSTER_VERSION="4.8"
export CLUSTER_IMAGE="quay.io/openshift-release-dev/ocp-release:4.8.2-x86_64"
export CLUSTER_NAME="kni1"
export CLUSTER_DOMAIN="schmaustech.com"
export CLUSTER_NET_TYPE="OVNKubernetes"
export MACHINE_CIDR_NET="192.168.0.0/24"
export SNO_STATICIP_NODE_NAME="master-0"
export PULL_SECRET=$(cat ~/pull-secret.json | jq -R .)
export CLUSTER_SSHKEY=$(cat ~/.ssh/id_rsa.pub)

refresh_token () {
export TOKEN=$(curl \
--silent \
--data-urlencode "grant_type=refresh_token" \
--data-urlencode "client_id=cloud-services" \
--data-urlencode "refresh_token=${OFFLINE_ACCESS_TOKEN}" \
https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token | \
jq -r .access_token)
}


echo "### Creating deployment.json..."
cat << EOF > ~/deployment.json
{
  "kind": "Cluster",
  "name": "$CLUSTER_NAME",
  "openshift_version": "$CLUSTER_VERSION",
  "ocp_release_image": "$CLUSTER_IMAGE",
  "base_dns_domain": "$CLUSTER_DOMAIN",
  "hyperthreading": "all",
  "user_managed_networking": true,
  "vip_dhcp_allocation": false,
  "high_availability_mode": "None",
  "hosts": [],
  "ssh_public_key": "$CLUSTER_SSHKEY",
  "pull_secret": $PULL_SECRET,
  "network_type": "OVNKubernetes"
}
EOF

refresh_token

echo "### Creating initial cluster configuration..."
export CLUSTER_ID=$( curl -s -X POST "https://$ASSISTED_SERVICE_API/api/assisted-install/v1/clusters" \
  -d @./deployment.json \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  | jq '.id' )

export CLUSTER_ID=$( sed -e 's/^"//' -e 's/"$//' <<<"$CLUSTER_ID")

echo "### Cluster ID: $CLUSTER_ID"

echo "### Configuring Static IP for SNO node..."
DATA=$(mktemp)

jq -n --arg SSH_KEY "$CLUSTER_SSHKEY" --arg NMSTATE_YAML1 "$(cat ~/sno-server.yaml)"  \
'{
  "ssh_public_key": $SSH_KEY,
  "image_type": "full-iso",
  "static_network_config": [
    {
      "network_yaml": $NMSTATE_YAML1,
      "mac_interface_map": [{"mac_address": "52:54:00:82:23:e2", "logical_nic_name": "ens9"}]
    }
  ]
}' >> $DATA

refresh_token

echo "### Updating the discovery.iso image with static IP information..."
curl -X POST \
  "https://$ASSISTED_SERVICE_API/api/assisted-install/v1/clusters/$CLUSTER_ID/downloads/image" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d @$DATA

echo "### Retrieving discovery.iso image..."
curl -L \
  "http://$ASSISTED_SERVICE_API/api/assisted-install/v1/clusters/$CLUSTER_ID/downloads/image" \
  -o ~/discovery-image-$CLUSTER_NAME.iso \
  -H "Authorization: Bearer $TOKEN"


echo "### Moving discovery.iso to bootable location for SNO server..."

scp ~/discovery-image-kni1.iso root@192.168.0.5:/slowdata/images/

/usr/bin/ipmitool -I lanplus -H192.168.0.10 -p6252 -Uadmin -Ppassword chassis power off

ssh root@192.168.0.5 "virsh change-media rhacm-master-0 hda /slowdata/images/discovery-image-kni1.iso"

ssh root@192.168.0.5 "virt-format --format=raw --partition=none -a /fastdata2/images/master-0.img"

/usr/bin/ipmitool -I lanplus -H192.168.0.10 -p6252 -Uadmin -Ppassword chassis power on

echo "### Waiting for discovery process..."
sleep 300


refresh_token  
echo "### Set the requested hostname for the SNO node..."
curl -X PATCH \
  "https://$ASSISTED_SERVICE_API/api/assisted-install/v1/clusters/$CLUSTER_ID" \
  -H "accept: application/json" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{ \"requested_hostname\": \"$SNO_STATICIP_NODE_NAME.$CLUSTER_NAME.$CLUSTER_DOMAIN\"}" | jq

echo "### Set the machine CIDR network..."
curl -X PATCH \
  "https://$ASSISTED_SERVICE_API/api/assisted-install/v1/clusters/$CLUSTER_ID" \
  -H "accept: application/json" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{ \"machine_network_cidr\": \"$MACHINE_CIDR_NET\"}" | jq

echo "### Start the installation process..."
curl -X POST \
  "https://$ASSISTED_SERVICE_API/api/assisted-install/v1/clusters/$CLUSTER_ID/actions/install" \
  -H "accept: application/json" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" | jq

echo "### Wait an hour or so..."
sleep 4500

refresh_token

echo "### Retrieve the kubeconfig for the cluster..."
curl -s -X GET \
  "https://$ASSISTED_SERVICE_API/api/assisted-install/v1/clusters/$CLUSTER_ID/downloads/kubeconfig" > kubeconfig-kni1 \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN"
