#!/usr/bin/env bash
SCENARIO_ROOT_DIR="$( cd -- "$(dirname "${0}")" >/dev/null 2>&1 ; pwd -P )"
ROOT_DIR=${1}
ACTION=${2}
source ${ROOT_DIR}/env.sh ${ROOT_DIR}
source ${ROOT_DIR}/certs.sh ${ROOT_DIR}
source ${ROOT_DIR}/helpers.sh
source ${ROOT_DIR}/tsb-helpers.sh

INSTALL_REPO_URL=$(get_install_repo_url) ;

if [[ ${ACTION} = "deploy" ]]; then

  # Set TSB_INSTALL_REPO_URL for envsubst of image repo
  export TSB_INSTALL_REPO_URL=${INSTALL_REPO_URL}

  # Login again as tsb admin in case of a session time-out
  login_tsb_admin tetrate ;

  # Deploy tsb cluster, organization-settings and tenant objects
  # Wait for clusters to be onboarded to avoid race conditions
  tctl apply -f ${SCENARIO_ROOT_DIR}/tsb/01-cluster.yaml ;
  sleep 5 ;
  wait_cluster_onboarded active-cluster ;
  wait_cluster_onboarded standby-cluster ;
  tctl apply -f ${SCENARIO_ROOT_DIR}/tsb/02-organization-setting.yaml ;
  tctl apply -f ${SCENARIO_ROOT_DIR}/tsb/03-tenant.yaml ;

  # Generate tier1 and tier2 ingress certificates for the application
  generate_server_cert abc demo.tetrate.io ;
  CERTS_BASE_DIR=$(get_certs_base_dir) ;

  # Deploy kubernetes objects in mgmt cluster
  kubectl --context mgmt-cluster apply -f ${SCENARIO_ROOT_DIR}/k8s/mgmt-cluster/01-namespace.yaml ;
  if ! kubectl --context mgmt-cluster get secret app-abc-cert -n gateway-tier1 &>/dev/null ; then
    kubectl --context mgmt-cluster create secret tls app-abc-cert -n gateway-tier1 \
      --key ${CERTS_BASE_DIR}/abc/server.abc.demo.tetrate.io-key.pem \
      --cert ${CERTS_BASE_DIR}/abc/server.abc.demo.tetrate.io-cert.pem ;
  fi
  kubectl --context mgmt-cluster apply -f ${SCENARIO_ROOT_DIR}/k8s/mgmt-cluster/02-tier1-gateway.yaml ;

  # Deploy kubernetes objects in active cluster
  kubectl --context active-cluster apply -f ${SCENARIO_ROOT_DIR}/k8s/active-cluster/01-namespace.yaml ;
  if ! kubectl --context active-cluster get secret app-abc-cert -n gateway-abc &>/dev/null ; then
    kubectl --context active-cluster create secret tls app-abc-cert -n gateway-abc \
      --key ${CERTS_BASE_DIR}/abc/server.abc.demo.tetrate.io-key.pem \
      --cert ${CERTS_BASE_DIR}/abc/server.abc.demo.tetrate.io-cert.pem ;
  fi
  kubectl --context active-cluster apply -f ${SCENARIO_ROOT_DIR}/k8s/active-cluster/02-service-account.yaml ;
  mkdir -p ${ROOT_DIR}/output/active-cluster/k8s ;
  envsubst < ${SCENARIO_ROOT_DIR}/k8s/active-cluster/03-deployment.yaml > ${ROOT_DIR}/output/active-cluster/k8s/03-deployment.yaml ;
  kubectl --context active-cluster apply -f ${ROOT_DIR}/output/active-cluster/k8s/03-deployment.yaml ;
  kubectl --context active-cluster apply -f ${SCENARIO_ROOT_DIR}/k8s/active-cluster/04-service.yaml ;
  kubectl --context active-cluster apply -f ${SCENARIO_ROOT_DIR}/k8s/active-cluster/05-eastwest-gateway.yaml ;
  kubectl --context active-cluster apply -f ${SCENARIO_ROOT_DIR}/k8s/active-cluster/06-ingress-gateway.yaml ;

  # Deploy kubernetes objects in standby cluster
  kubectl --context standby-cluster apply -f ${SCENARIO_ROOT_DIR}/k8s/standby-cluster/01-namespace.yaml ;
  if ! kubectl --context standby-cluster get secret app-abc-cert -n gateway-abc &>/dev/null ; then
    kubectl --context standby-cluster create secret tls app-abc-cert -n gateway-abc \
      --key ${CERTS_BASE_DIR}/abc/server.abc.demo.tetrate.io-key.pem \
      --cert ${CERTS_BASE_DIR}/abc/server.abc.demo.tetrate.io-cert.pem ;
  fi
  kubectl --context standby-cluster apply -f ${SCENARIO_ROOT_DIR}/k8s/standby-cluster/02-service-account.yaml ;
  mkdir -p ${ROOT_DIR}/output/standby-cluster/k8s ;
  envsubst < ${SCENARIO_ROOT_DIR}/k8s/standby-cluster/03-deployment.yaml > ${ROOT_DIR}/output/standby-cluster/k8s/03-deployment.yaml ;
  kubectl --context standby-cluster apply -f ${ROOT_DIR}/output/standby-cluster/k8s/03-deployment.yaml ;
  kubectl --context standby-cluster apply -f ${SCENARIO_ROOT_DIR}/k8s/standby-cluster/04-service.yaml ;
  kubectl --context standby-cluster apply -f ${SCENARIO_ROOT_DIR}/k8s/standby-cluster/05-eastwest-gateway.yaml ;
  kubectl --context standby-cluster apply -f ${SCENARIO_ROOT_DIR}/k8s/standby-cluster/06-ingress-gateway.yaml ;

  # Deploy tsb objects
  tctl apply -f ${SCENARIO_ROOT_DIR}/tsb/04-workspace.yaml ;
  tctl apply -f ${SCENARIO_ROOT_DIR}/tsb/05-workspace-setting.yaml ;
  tctl apply -f ${SCENARIO_ROOT_DIR}/tsb/06-group.yaml ;
  tctl apply -f ${SCENARIO_ROOT_DIR}/tsb/07-tier1-gateway.yaml ;
  tctl apply -f ${SCENARIO_ROOT_DIR}/tsb/08-ingress-gateway.yaml ;
  tctl apply -f ${SCENARIO_ROOT_DIR}/tsb/09-security-setting.yaml ;

  exit 0
fi


if [[ ${ACTION} = "undeploy" ]]; then

  # Login again as tsb admin in case of a session time-out
  login_tsb_admin tetrate ;

  # Delete tsb configuration
  for TSB_FILE in $(ls -1 ${SCENARIO_ROOT_DIR}/tsb | sort -r) ; do
    echo "Going to delete tsb/${TSB_FILE}"
    tctl delete -f ${SCENARIO_ROOT_DIR}/tsb/${TSB_FILE} 2>/dev/null ;
  done

  # Delete kubernetes configuration in mgmt, active and standby cluster
  kubectl --context mgmt-cluster delete -f ${SCENARIO_ROOT_DIR}/k8s/mgmt-cluster 2>/dev/null ;
  kubectl --context active-cluster delete -f ${ROOT_DIR}/output/active-cluster/k8s/03-deployment.yaml 2>/dev/null ;
  kubectl --context active-cluster delete -f ${SCENARIO_ROOT_DIR}/k8s/active-cluster 2>/dev/null ;
  kubectl --context standby-cluster delete -f ${ROOT_DIR}/output/standby-cluster/k8s/03-deployment.yaml 2>/dev/null ;
  kubectl --context standby-cluster delete -f ${SCENARIO_ROOT_DIR}/k8s/standby-cluster 2>/dev/null ;

  exit 0
fi


if [[ ${ACTION} = "info" ]]; then

  while ! T1_GW_IP=$(kubectl --context mgmt-cluster get svc -n gateway-tier1 gw-tier1-abc --output jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) ; do
    sleep 1;
  done
  while ! INGRESS_ACTIVE_GW_IP=$(kubectl --context active-cluster get svc -n gateway-abc gw-ingress-abc --output jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) ; do
    sleep 1;
  done
  while ! INGRESS_STANDBY_GW_IP=$(kubectl --context standby-cluster get svc -n gateway-abc gw-ingress-abc --output jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) ; do
    sleep 1;
  done

  CERTS_BASE_DIR=$(get_certs_base_dir) ;

  print_info "****************************"
  print_info "*** ABC Traffic Commands ***"
  print_info "****************************"
  echo
  echo "Traffic to Active Ingress Gateway"
  print_command "curl -v -H \"X-B3-Sampled: 1\" --resolve \"abc.demo.tetrate.io:443:${INGRESS_ACTIVE_GW_IP}\" --cacert ${CERTS_BASE_DIR}/root-cert.pem \"https://abc.demo.tetrate.io/proxy/app-b.ns-b/proxy/app-c.ns-c\""
  echo "Traffic to Standby Ingress Gateway"
  print_command "curl -v -H \"X-B3-Sampled: 1\" --resolve \"abc.demo.tetrate.io:443:${INGRESS_STANDBY_GW_IP}\" --cacert ${CERTS_BASE_DIR}/root-cert.pem \"https://abc.demo.tetrate.io/proxy/app-b.ns-b/proxy/app-c.ns-c\""
  echo "Traffic through T1 Gateway"
  print_command "curl -v -H \"X-B3-Sampled: 1\" --resolve \"abc.demo.tetrate.io:443:${T1_GW_IP}\" --cacert ${CERTS_BASE_DIR}/root-cert.pem \"https://abc.demo.tetrate.io/proxy/app-b.ns-b/proxy/app-c.ns-c\""
  echo
  echo "All at once in a loop"
  print_command "while true ; do
  curl -v -H \"X-B3-Sampled: 1\" --resolve \"abc.demo.tetrate.io:443:${T1_GW_IP}\" --cacert ${CERTS_BASE_DIR}/root-cert.pem \"https://abc.demo.tetrate.io/proxy/app-b.ns-b/proxy/app-c.ns-c\"
  sleep 1 ;
done"
  echo
  exit 0
fi


echo "Please specify one of the following action:"
echo "  - deploy"
echo "  - undeploy"
echo "  - info"
exit 1
