#!/usr/bin/env bash

ACTION=${1}
K8S_VERSION=${2}

MINIKUBE_NETWORK=tsb-demo

MGMT_CLUSTER_PROFILE=mgmt-cluster-m1
MGMT_CLUSTER_METALLB_STARTIP=100
MGMT_CLUSTER_METALLB_ENDIP=149

ACTIVE_CLUSTER_PROFILE=active-cluster-m2
ACTIVE_CLUSTER_METALLB_STARTIP=150
ACTIVE_CLUSTER_METALLB_ENDIP=199

STANDBY_CLUSTER_PROFILE=standby-cluster-m3
STANDBY_CLUSTER_METALLB_STARTIP=200
STANDBY_CLUSTER_METALLB_ENDIP=249

# Configure metallb start and end IP
#   args:
#     (1) minikube profile name
#     (2) start ip
#     (3) end ip
function configure_metallb {
  expect <<DONE
  spawn minikube --profile ${1} addons configure metallb
  expect "Enter Load Balancer Start IP:" { send "${2}\\r" }
  expect "Enter Load Balancer End IP:" { send "${3}\\r" }
  expect eof
DONE
}

# Pull tsb docker images 
function sync_images {
  docker login -u ${TSB_DOCKER_USERNAME} -p ${TSB_DOCKER_PASSWORD} containers.dl.tetrate.io ;

  # Sync all tsb images locally (if not yet available)
  for image in `tctl install image-sync --just-print --raw --accept-eula` ; do
    if ! docker image inspect ${image} &>/dev/null ; then
      docker pull ${image} ;
    fi
  done

  # Sync image for application deployment
  if ! docker image inspect containers.dl.tetrate.io/obs-tester-server:1.0 &>/dev/null ; then
    docker pull containers.dl.tetrate.io/obs-tester-server:1.0 ;
  fi

  # Sync image for debugging
  if ! docker image inspect containers.dl.tetrate.io/netshoot &>/dev/null ; then
    docker pull containers.dl.tetrate.io/netshoot ;
  fi
}

# Load docker images into minikube profile 
#   args:
#     (1) minikube profile name
function load_images {
  for image in `tctl install image-sync --just-print --raw --accept-eula` ; do
    if ! minikube --profile ${1} image ls | grep ${image} &>/dev/null ; then
      echo "Syncing image ${image} to minikube profile ${1}" ;
      minikube --profile ${1} image load ${image} ;
    fi
  done

  # Load image for application deployment
  if ! minikube --profile ${1} image ls | grep containers.dl.tetrate.io/obs-tester-server:1.0 &>/dev/null ; then
    echo "Syncing image containers.dl.tetrate.io/obs-tester-server:1.0 to minikube profile ${1}" ;
    minikube --profile ${1} image load containers.dl.tetrate.io/obs-tester-server:1.0 ;
  fi

  # Load image for debugging
  if ! minikube --profile ${1} image ls | grep containers.dl.tetrate.io/netshoot &>/dev/null ; then
    echo "Syncing image containers.dl.tetrate.io/netshoot to minikube profile ${1}" ;
    minikube --profile ${1} image load containers.dl.tetrate.io/netshoot ;
  fi
}

if [[ ${ACTION} = "up" ]]; then
  # MINIKUBE_MGMT_CLUSTER_OPTS="--driver kvm --cpus=6 --memory=11g"
  # MINIKUBE_APP_CLUSTER_OPTS="--driver kvm --cpus=6 --memory=9g"

  # Start minikube profiles for all clusters
  minikube start --kubernetes-version=v${K8S_VERSION} --profile ${MGMT_CLUSTER_PROFILE} --network ${MINIKUBE_NETWORK} ${MINIKUBE_MGMT_CLUSTER_OPTS} ;
  minikube start --kubernetes-version=v${K8S_VERSION} --profile ${ACTIVE_CLUSTER_PROFILE} --network ${MINIKUBE_NETWORK} ${MINIKUBE_APP_CLUSTER_OPTS} ;
  minikube start --kubernetes-version=v${K8S_VERSION} --profile ${STANDBY_CLUSTER_PROFILE} --network ${MINIKUBE_NETWORK} ${MINIKUBE_APP_CLUSTER_OPTS} ;

  # Extract the docker/minikube network subnet (default 192.168.49.0/24)
  # If another docker/minikube subnet pre-existed, it will be a different subnet
  # MINIKUBE_NETWORK_SUBNET=$(docker network inspect ${MINIKUBE_NETWORK} | jq -r .[].IPAM.Config[0].Subnet | awk -F '.' '{ print $1"."$2"."$3".";}')
  MINIKUBE_NETWORK_SUBNET=$(minikube ip --profile ${MGMT_CLUSTER_PROFILE} | awk -F '.' '{ print $1"."$2"."$3".";}')

  # Configure and enable metallb in all clusters
  configure_metallb ${MGMT_CLUSTER_PROFILE} ${MINIKUBE_NETWORK_SUBNET}${MGMT_CLUSTER_METALLB_STARTIP} ${MINIKUBE_NETWORK_SUBNET}${MGMT_CLUSTER_METALLB_ENDIP} ;
  configure_metallb ${ACTIVE_CLUSTER_PROFILE} ${MINIKUBE_NETWORK_SUBNET}${ACTIVE_CLUSTER_METALLB_STARTIP} ${MINIKUBE_NETWORK_SUBNET}${ACTIVE_CLUSTER_METALLB_ENDIP} ;
  configure_metallb ${STANDBY_CLUSTER_PROFILE} ${MINIKUBE_NETWORK_SUBNET}${STANDBY_CLUSTER_METALLB_STARTIP} ${MINIKUBE_NETWORK_SUBNET}${STANDBY_CLUSTER_METALLB_ENDIP} ;

  minikube --profile ${MGMT_CLUSTER_PROFILE} addons enable metallb ;
  minikube --profile ${ACTIVE_CLUSTER_PROFILE} addons enable metallb ;
  minikube --profile ${STANDBY_CLUSTER_PROFILE} addons enable metallb ;

  # Pull images locally and sync them to minikube profiles
  sync_images ;
  load_images ${MGMT_CLUSTER_PROFILE} &
  pid_load_images_mgmt_cluster=$!
  load_images ${ACTIVE_CLUSTER_PROFILE} &
  pid_load_images_active_cluster=$!
  load_images ${STANDBY_CLUSTER_PROFILE} &
  pid_load_images_standby_cluster=$!
  wait $pid_load_images_mgmt_cluster
  wait $pid_load_images_active_cluster
  wait $pid_load_images_standby_cluster

  # Add nodes labels for locality based routing (region and zone)
  kubectl --context ${MGMT_CLUSTER_PROFILE} label node ${MGMT_CLUSTER_PROFILE} topology.kubernetes.io/region=region1 --overwrite=true ;
  kubectl --context ${ACTIVE_CLUSTER_PROFILE} label node ${ACTIVE_CLUSTER_PROFILE} topology.kubernetes.io/region=region1 --overwrite=true ;
  kubectl --context ${STANDBY_CLUSTER_PROFILE} label node ${STANDBY_CLUSTER_PROFILE} topology.kubernetes.io/region=region2 --overwrite=true ;

  kubectl --context ${MGMT_CLUSTER_PROFILE} label node ${MGMT_CLUSTER_PROFILE} topology.kubernetes.io/zone=zone1a --overwrite=true ;
  kubectl --context ${ACTIVE_CLUSTER_PROFILE} label node ${ACTIVE_CLUSTER_PROFILE} topology.kubernetes.io/zone=zone1b --overwrite=true ;
  kubectl --context ${STANDBY_CLUSTER_PROFILE} label node ${STANDBY_CLUSTER_PROFILE} topology.kubernetes.io/zone=zone2a --overwrite=true ;

  exit 0
fi

if [[ ${ACTION} = "down" ]]; then

  # Stop and delete minikube profiles
  minikube stop --profile ${MGMT_CLUSTER_PROFILE} ;
  minikube stop --profile ${ACTIVE_CLUSTER_PROFILE} ;
  minikube stop --profile ${STANDBY_CLUSTER_PROFILE} ;

  minikube delete --profile ${MGMT_CLUSTER_PROFILE} ;
  minikube delete --profile ${ACTIVE_CLUSTER_PROFILE} ;
  minikube delete --profile ${STANDBY_CLUSTER_PROFILE} ;

  exit 0
fi

echo "Please specify correct action: up/down"
exit 1