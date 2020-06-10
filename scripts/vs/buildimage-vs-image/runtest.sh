#!/bin/bash -xe

run_pytest()
{
    tgname=$1
    shift
    tests=$@

    echo "run tests: $tests"

    mkdir -p logs/$tgname
    for tn in ${tests}; do
        tdir=$(dirname $tn)
        if [ $tdir != "." ]; then
            mkdir -p logs/$tgname/$tdir
            mkdir -p results/$tgname/$tdir
        fi
        py.test $PYTEST_COMMON_OPTS --log-file logs/$tgname/$tn.log --junitxml=results/$tgname/$tn.xml $tn.py
    done
}

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
    testbed_name="vms-kvm-t0"
else
    testbed_name="vms-kvm-t0-2"
fi

# TODO: There are some improvements we could make to this script.
#
# 1. We should take advantage of the markers in sonic-mgmt to control the test selection.
#    Currently the test cases are hardcoded in this file which makes it difficult to pilot
#    new test cases for the PR runners. If we use markers then we can open PRs against sonic-mgmt
#    to add new test cases and limit the blast radius to the test run for that particular PR.
#
# 2. This script can probably be modularized a bit better to help with readability.

cd $HOME
mkdir -p .ssh
cp /data/pkey.txt .ssh/id_rsa
chmod 600 .ssh/id_rsa

# Refresh virtual switch with testbed topology
cd /data/sonic-mgmt/ansible
./testbed-cli.sh -m veos.vtb -t vtestbed.csv refresh-dut $testbed_name password.txt
sleep 120

# Create and deploy default vlan configuration (one_vlan_a) to the virtual switch
./testbed-cli.sh -m veos.vtb -t vtestbed.csv deploy-mg $testbed_name lab password.txt
sleep 180

export ANSIBLE_LIBRARY=/data/sonic-mgmt/ansible/library/

# workaround for issue https://github.com/Azure/sonic-mgmt/issues/1659
export export ANSIBLE_KEEP_REMOTE_FILES=1

PYTEST_COMMON_OPTS="--inventory veos.vtb \
                    --host-pattern all \
                    --user admin \
                    -vvv \
                    --show-capture stdout \
                    --testbed $testbed_name \
                    --testbed_file vtestbed.csv \
                    --disable_loganalyzer \
                    --log-file-level debug"

# Check testbed health
cd /data/sonic-mgmt/tests
rm -rf logs results
mkdir -p logs
mkdir -p results
py.test $PYTEST_COMMON_OPTS --log-file logs/test_nbr_health.log --junitxml=results/tr.xml test_nbr_health.py

# Run anounce route test case in order to populate BGP route
py.test $PYTEST_COMMON_OPTS --log-file logs/test_announce_routes.log --junitxml=results/tr.xml test_announce_routes.py

# Tests to run using one vlan configuration
tgname=1vlan
tests="\
    test_interfaces \
    pc/test_po_update \
    bgp/test_bgp_fact \
    lldp/test_lldp \
    route/test_default_route \
    bgp/test_bgp_speaker \
    bgp/test_bgp_gr_helper \
    dhcp_relay/test_dhcp_relay \
    tacacs/test_rw_user \
    tacacs/test_ro_user \
    ntp/test_ntp \
    cacl/test_control_plane_acl \
    snmp/test_snmp_cpu \
    snmp/test_snmp_interfaces \
    snmp/test_snmp_lldp \
    snmp/test_snmp_pfc_counters \
    snmp/test_snmp_queue
"

# Run tests_1vlan on vlab-01 virtual switch
pushd /data/sonic-mgmt/tests
run_pytest $tgname $tests
popd

# Create and deploy two vlan configuration (two_vlan_a) to the virtual switch
cd /data/sonic-mgmt/ansible
./testbed-cli.sh -m veos.vtb -t vtestbed.csv deploy-mg $testbed_name lab password.txt -e vlan_config=two_vlan_a
sleep 180

# Tests to run using two vlan configuration
tgname=2vlans
tests="\
    dhcp_relay/test_dhcp_relay \
"

# Run tests_2vlans on vlab-01 virtual switch
pushd /data/sonic-mgmt/tests
run_pytest $tgname $tests
popd

) 200>/var/lock/kvm_lock # END OF CRITICAL SECTION
