#!/bin/sh

set -x -e

# Reuse the data directory chosen by the initial installer so the existing
# rancher2_connection_info.json is found. The image default may differ from
# the path used by the bootstrap on transactional systems.
config_dir=${CATTLE_AGENT_CONFIG_DIR:-/etc/rancher/agent}
config_file="/host${config_dir}/config.yaml"
if [ -f "${config_file}" ]; then
    line=$(grep -m1 '^workDirectory:' "${config_file}" 2>/dev/null || true)
    dir=${line#workDirectory: }
    dir=${dir%/work}
    if [ -n "${dir}" ] && [ "${dir}" != "${line}" ]; then
        export CATTLE_AGENT_VAR_DIR="${dir}"
    fi
fi

# The upgrader only replaces the agent binary. Re-registering would create a
# custom-<hash> Machine when cattle-id is not visible; install.sh falls back to
# registration if the existing connection info is missing. Set
# CATTLE_SKIP_REGISTRATION=false in the Plan to force re-registration.
if [ -z "${CATTLE_SKIP_REGISTRATION}" ]; then
    CATTLE_SKIP_REGISTRATION=true
fi
export CATTLE_SKIP_REGISTRATION

CATTLE_AGENT_VAR_DIR=${CATTLE_AGENT_VAR_DIR:-/var/lib/rancher/agent}
TMPDIRBASE=${CATTLE_AGENT_VAR_DIR}/tmp

mkdir -p "/host${TMPDIRBASE}"

TMPDIR=$(chroot /host /bin/sh -c "mktemp -d -p ${TMPDIRBASE}")

cleanup() {
    rm -rf "/host${TMPDIR}"
}

trap cleanup EXIT
trap exit INT HUP TERM

cp /opt/rancher-system-agent-suc/install.sh "/host${TMPDIR}"
cp /opt/rancher-system-agent-suc/rancher-system-agent "/host${TMPDIR}"
cp /opt/rancher-system-agent-suc/system-agent-uninstall.sh "/host${TMPDIR}/rancher-system-agent-uninstall.sh"
chmod +x "/host${TMPDIR}/install.sh"
chmod +x "/host${TMPDIR}/rancher-system-agent-uninstall.sh"

if [ -n "$SYSTEM_UPGRADE_NODE_NAME" ]; then
    NODE_FILE=/host${TMPDIR}/node.yaml
    kubectl get node ${SYSTEM_UPGRADE_NODE_NAME} -o yaml > $NODE_FILE
    if [ -z "$CATTLE_ROLE_ETCD" ] && grep -q 'node-role.kubernetes.io/etcd: "true"' $NODE_FILE; then
        export CATTLE_ROLE_ETCD=true
    fi
    if [ -z "$CATTLE_ROLE_CONTROLPLANE" ] && grep -q 'node-role.kubernetes.io/controlplane: "true"' $NODE_FILE; then
        export CATTLE_ROLE_CONTROLPLANE=true
    fi
    if [ -z "$CATTLE_ROLE_CONTROLPLANE" ] && grep -q 'node-role.kubernetes.io/control-plane: "true"' $NODE_FILE; then
        export CATTLE_ROLE_CONTROLPLANE=true
    fi
    if [ -z "$CATTLE_ROLE_WORKER" ] && grep -q 'node-role.kubernetes.io/worker: "true"' $NODE_FILE; then
        export CATTLE_ROLE_WORKER=true
    fi
    export CATTLE_NODE_NAME="${SYSTEM_UPGRADE_NODE_NAME}"
fi

export CATTLE_AGENT_BINARY_LOCAL=true
export CATTLE_AGENT_UNINSTALL_LOCAL=true
export CATTLE_AGENT_BINARY_LOCAL_LOCATION=${TMPDIR}/rancher-system-agent
export CATTLE_AGENT_UNINSTALL_LOCAL_LOCATION=${TMPDIR}/rancher-system-agent-uninstall.sh

RUN_SCRIPT=${TMPDIR}/install.sh
if [ "${UNINSTALL}" = "true" ]; then
    RUN_SCRIPT=${TMPDIR}/rancher-system-agent-uninstall.sh
fi

chroot /host "${RUN_SCRIPT}" "$@" &
# wait on the install script to free up trap handling
# ref: https://www.gnu.org/software/bash/manual/html_node/Signals.html#Signals-1
# removal of the above chroot process will occur during cgroup cleanup
wait $!
