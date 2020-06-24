#!/bin/bash -x

echo ${JOB_NAME##*/}.${BUILD_NUMBER}

ls -l
virsh -c qemu:///system list

( # START OF CRITICAL SECTION

# NOTE: Jenkins currently limits each worker to 2 KVM jobs at once. So, we only need
# one lock to maintain consistency. The logic is:
#
# - If we are able to grab the lock, then vms-kvm-t0 is not in use. So, we are free
#   to use this testbed, regardless of whether vms-kvm-t0-2 is currently being used
#   or not.
#
# - If we are not able to grab the lock, then vms-kvm-t0 is in use. Since we are limited
#   to 2 jobs per node, that means vms-kvm-t0-2 is not currently in use, so we are free
#   to use that testbed.
#
# This logic may need to be refined as we add more testbeds, but it should work for now.
TESTBED_1_LOCK_HELD=0
flock -xn 200 || TESTBED_1_LOCK_HELD=$?

if [ $TESTBED_1_LOCK_HELD -eq 0 ] ; then
    tbname=vms-kvm-t0
    dut=vlab-01
else
    tbname=vms-kvm-t0-2
    dut=vlab-04
fi

docker login -u $REGISTRY_USERNAME -p $REGISTRY_PASSWD sonicdev-microsoft.azurecr.io:443
docker pull sonicdev-microsoft.azurecr.io:443/docker-sonic-mgmt:latest

cat $VM_USER_PRIVATE_KEY > pkey.txt

mkdir -p $HOME/sonic-vm/images
if [ -e target/sonic-vs.img.gz ]; then
    cp target/sonic-vs.img.gz $HOME/sonic-vm/images/
else
    sudo cp /nfs/jenkins/sonic-vs-${JOB_NAME##*/}.${BUILD_NUMBER}.img.gz $HOME/sonic-vm/images/sonic-vs.img.gz
fi
gzip -fd $HOME/sonic-vm/images/sonic-vs.img.gz

ls -l $HOME/sonic-vm/images

cd sonic-mgmt/ansible
sed -i s:use_own_value:johnar: veos.vtb
echo abc > password.txt
cd ../../
docker run --rm=true -v $(pwd):/data -w /data -i sonicdev-microsoft.azurecr.io:443/docker-sonic-mgmt ./scripts/vs/buildimage-vs-image/runtest.sh $tbname

# save dut state if test fails
if [ $? != 0 ]; then
    virsh_version=$(virsh --version)
    if [ $virsh_version == "6.0.0" ]; then
        rm -rf kvmdump
        mkdir -p kvmdump
        virsh -c qemu:///system list
        virsh -c qemu:///system save $dut kvmdump/$dut.memdmp
        virsh -c qemu:///system dumpxml $dut > kvmdump/$dut.xml
        img=$(virsh -c qemu:///system domblklist $dut | grep vda | awk '{print $2}')
        cp $img kvmdump/$dut.img
        sudo chown -R johnar.johnar kvmdump
        virsh -c qemu:///system undefine $dut
    fi
    exit 2
fi

) 200>/var/lock/kvm_lock # END OF CRITICAL SECTION
