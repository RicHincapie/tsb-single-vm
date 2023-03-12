#!/usr/bin/env bash
ROOT_DIR=${1}
OUTPUT_DIR=${ROOT_DIR}/output

ENV_CONF=env.json
if ! [[ -f "${ENV_CONF}" ]] ; then
  echo "Cannot find ${ENV_CONF}, aborting..."
  exit 1
fi

if ! cat ${ENV_CONF} | jq -r ".topology" &>/dev/null ; then
  echo "Unable to parse topology from ${ENV_CONF}, aborting..."
  exit 2
fi

function get_topology {
  cat ${ENV_CONF} | jq -r ".topology"
}
function get_scenario {
  cat ${ENV_CONF} | jq -r ".scenario"
}
function get_topology_dir {
  echo ${ROOT_DIR}/topologies/$(get_topology)
}
function get_scenario_dir {
  echo ${ROOT_DIR}/scenarios/$(get_topology)/$(get_scenario)
}

TOPOLOGY_CONF=$(get_topology_dir)/infra.json
if ! [[ -f "${TOPOLOGY_CONF}" ]] ; then
  echo "Cannot find ${TOPOLOGY_CONF}, aborting..."
  exit 3
fi


### Infra Configuration ###

function get_istioctl_version {
  cat ${TOPOLOGY_CONF} | jq -r ".istioctl_version"
}

function get_k8s_version {
  cat ${TOPOLOGY_CONF} | jq -r ".k8s_version"
}

###### MP Cluster ######

function get_mp_minikube_profile {
  echo $(cat ${TOPOLOGY_CONF} | jq -r ".mp_cluster.name")-m1
}

function get_mp_name {
  cat ${TOPOLOGY_CONF} | jq -r ".mp_cluster.name"
}

function get_mp_region {
  cat ${TOPOLOGY_CONF} | jq -r ".mp_cluster.region"
}

function get_mp_vm_count {
  cat ${TOPOLOGY_CONF} | jq -r ".mp_cluster.vms[].name" | wc -l | tr -d ' '
}

function get_mp_vm_image_by_index {
  i=${1}
  cat ${TOPOLOGY_CONF} | jq -r ".mp_cluster.vms[${i}].image"
}

function get_mp_vm_name_by_index {
  i=${1}
  cat ${TOPOLOGY_CONF} | jq -r ".mp_cluster.vms[${i}].name"
}

function get_mp_zone {
  cat ${TOPOLOGY_CONF} | jq -r ".mp_cluster.zone"
}

###### CP Clusters ######

function get_cp_count {
  cat ${TOPOLOGY_CONF} | jq -r ".cp_clusters[].name" | wc -l | tr -d ' '
}

function get_cp_minikube_profile_by_index {
  i=${1}
  echo $(cat ${TOPOLOGY_CONF} | jq -r ".cp_clusters[${i}].name")-m$((i+2))
}

function get_cp_name_by_index {
  i=${1}
  cat ${TOPOLOGY_CONF} | jq -r ".cp_clusters[${i}].name"
}

function get_cp_vm_count_by_index {
  i=${1}
  j=${2}
  cat ${TOPOLOGY_CONF} | jq -r ".cp_clusters[${i}].vms[].name" | wc -l | tr -d ' '
}

function get_cp_vm_image_by_index {
  i=${1}
  j=${2}
  cat ${TOPOLOGY_CONF} | jq -r ".cp_clusters[${i}].vms[${j}].image"
}

function get_cp_vm_name_by_index {
  i=${1}
  j=${2}
  cat ${TOPOLOGY_CONF} | jq -r ".cp_clusters[${i}].vms[${j}].name"
}

function get_cp_region_by_index {
  i=${1}
  cat ${TOPOLOGY_CONF} | jq -r ".cp_clusters[${i}].region"
}

function get_cp_zone_by_index {
  i=${1}
  cat ${TOPOLOGY_CONF} | jq -r ".cp_clusters[${i}].zone"
}


### TSB Configuration ###

function get_tsb_repo_password {
  cat ${ENV_CONF} | jq -r ".tsb.repo.password"
}
function get_tsb_repo_url {
  cat ${ENV_CONF} | jq -r ".tsb.repo.url"
}

function get_tsb_repo_user {
  cat ${ENV_CONF} | jq -r ".tsb.repo.user"
}

function get_tsb_version {
  cat ${ENV_CONF} | jq -r ".tsb.version"
}


### Configuration and output directories ###
function get_mp_config_dir {
  echo ${TOPOLOGY_DIR}/$(get_mp_name)
}

function get_mp_output_dir {
  mkdir -p ${OUTPUT_DIR}/$(get_mp_name)
  echo ${OUTPUT_DIR}/$(get_mp_name)
}

function get_cp_config_dir {
  i=${1}
  echo ${TOPOLOGY_DIR}/$(get_cp_name_by_index ${i})
}

function get_cp_output_dir {
  i=${1}
  mkdir -p ${OUTPUT_DIR}/$(get_cp_name_by_index ${i})
  echo ${OUTPUT_DIR}/$(get_cp_name_by_index ${i})
}

### Parsing Tests
#
# get_istioctl_version;
# get_k8s_version;
# get_mp_minikube_profile;
# get_mp_name;
# get_mp_region;
# get_mp_vm_count;
# get_mp_vm_image_by_index 0;
# get_mp_vm_image_by_index 1;
# get_mp_vm_name_by_index 0;
# get_mp_vm_name_by_index 1;
# get_mp_zone;
# get_cp_count;
# get_cp_name_by_index 0;
# get_cp_region_by_index 0;
# get_cp_zone_by_index 0;
# get_cp_name_by_index 1;
# get_cp_vm_count_by_index 0;
# get_cp_vm_name_by_index 0 0;
# get_cp_vm_name_by_index 0 1;
# get_cp_vm_image_by_index 0 0;
# get_cp_vm_image_by_index 0 1;
# get_cp_vm_count_by_index 1;
# get_cp_vm_name_by_index 1 0;
# get_cp_vm_name_by_index 1 1;
# get_cp_vm_image_by_index 1 0;
# get_cp_vm_image_by_index 1 1;
# get_cp_region_by_index 1;
# get_cp_zone_by_index 1;
# get_cp_minikube_profile_by_index 0;
# get_cp_minikube_profile_by_index 1;

# get_tsb_repo_password;
# get_tsb_repo_url;
# get_tsb_repo_user;
# get_tsb_version;

# get_certs_base_dir;
# get_mp_config_dir;
# get_mp_output_dir;
# get_cp_config_dir 0;
# get_cp_output_dir 0;
# get_cp_config_dir 1;
# get_cp_output_dir 1;

# get_scenario_dir;