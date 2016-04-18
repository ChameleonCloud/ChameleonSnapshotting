#/bin/bash

HOSTNAME=$(hostname)
UUID=$(uuidgen)

if [ "$1" == "" ]; then
    SNAPSHOT_NAME="$HOSTNAME_$UUID"
else
    SNAPSHOT_NAME="$1"
fi

echo "Will snapshot the instance using the $SNAPSHOT_NAME name"

IS_UBUNTU=false
IS_CENTOS=$(if [ -f /etc/redhat-release ]; then echo "true"; else echo "false"; fi)


#########################################################
# Generate openrc file that will be used to upload image
#########################################################

# The extract_json_key function is in charge of find a key in a flat JSON value.
# Please note that if the JSON value is not flat, it should return the first value
# associated to the given key.
#    $1: String that represents the key
#    $2: String that represents the JSON value
#    return: the value of the key in the JSON value
# example: extract_json_key 'foo' '{"foo": 1, "bar": 2}'

function extract_json_key {
    RESULT=$(echo "$2" | sed "s/.*$1\": \"//g" | sed 's/".*//g')
    echo "$RESULT"
}

JSON_VENDOR_DATA=$(curl http://169.254.169.254/openstack/latest/vendor_data.json)
SITE=$(extract_json_key "site" "$JSON_VENDOR_DATA")
USER_ID=$(extract_json_key "user_id" "$JSON_VENDOR_DATA")
PROJECT_ID=$(extract_json_key "project_id" "$JSON_VENDOR_DATA")

cat > openrc <<- EOM
#!/bin/bash

# To use an OpenStack cloud you need to authenticate against the Identity
# service named keystone, which returns a **Token** and **Service Catalog**.
# The catalog contains the endpoints for all services the user/tenant has
# access to - such as Compute, Image Service, Identity, Object Storage, Block
# Storage, and Networking (code-named nova, glance, keystone, swift,
# cinder, and neutron).
#
# *NOTE*: Using the 2.0 *Identity API* does not necessarily mean any other
# OpenStack API is version 2.0. For example, your cloud provider may implement
# Image API v1.1, Block Storage API v2, and Compute API v2.0. OS_AUTH_URL is
# only for the Identity API served through keystone.
export OS_AUTH_URL=https://chi.$SITE.chameleoncloud.org:5000/v2.0

# With the addition of Keystone we have standardized on the term **tenant**
# as the entity that owns the resources.
export OS_TENANT_ID=$PROJECT_ID
export OS_TENANT_NAME="$PROJECT_ID"
export OS_PROJECT_NAME="$PROJECT_ID"

# In addition to the owning entity (tenant), OpenStack stores the entity
# performing the action as the **user**.
export OS_USERNAME="$USER_ID"

# With Keystone you pass the keystone password.
echo "Please enter your OpenStack Password: "
read -sr OS_PASSWORD_INPUT
export OS_PASSWORD=\$OS_PASSWORD_INPUT

# If your configuration has multiple regions, we set that information here.
# OS_REGION_NAME is optional and only valid in certain environments.
export OS_REGION_NAME="regionOne"
# Don't leave a blank variable, unset it if it was empty
if [ -z "\$OS_REGION_NAME" ]; then unset OS_REGION_NAME; fi
EOM

# Source the file that has been generated above
source openrc

#################################
# Begin the snapshotting process
#################################

if [ "$IS_CENTOS" == true ]; then
    # Install prerequisite software (only required for XFS file systems, which is the default on CentOS 7):
    yum install -y libguestfs-xfs
fi

# Create a tar file of the contents of your instance:
tar cf /tmp/snapshot.tar / --selinux --acls --xattrs --numeric-owner --one-file-system --exclude=/tmp/* --exclude=/proc/* --exclude=/boot/extlinux

if [ "$IS_UBUNTU" == true ]; then
    # Update guestfs appliances (prevent an error with virt-make-fs)
    update-guestfs-appliance
fi

# This will take 3 to 5 minutes. Next, convert the tar file into a qcow2 image (if you don't want to use the XFS file system, you can replace xfs by ext4):
virt-make-fs --partition --format=qcow2 --type=xfs --label=img-rootfs /tmp/snapshot.tar /tmp/snapshot.qcow2

if [ "$IS_CENTOS" == true ]; then
    # and looking at the name of the file in that directory. Next ensure that the GRUB bootloader is present in the image:
    virt-customize -a /tmp/snapshot.qcow2 --run-command 'grub2-install /dev/sda && grub2-mkconfig -o /boot/grub2/grub.cfg'
fi

if [ "$IS_UBUNTU" == true ]; then
    # Next ensure that the GRUB bootloader is present in the image:
    guestfish -a /tmp/snapshot.qcow2 -i sh 'grub-install /dev/sda && grub-mkconfig -o /boot/grub/grub.cfg'
fi

# To remove unwanted configuration information from your image, run:
virt-sysprep -a /tmp/snapshot.qcow2

# To complete the preparation of your snapshot image, create a compressed version of it:
qemu-img convert /tmp/snapshot.qcow2 -O qcow2 /tmp/snapshot_compressed.qcow2 -c

################################
# Upload the Snapshot on Glance
################################

# The final steps are to upload your snapshot image to OpenStack Glance.
glance image-create --name $SNAPSHOT_NAME --disk-format qcow2 --container-format bare < /tmp/snapshot_compressed.qcow2

