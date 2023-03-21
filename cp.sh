#!/usr/bin/env bash

ROOT_DIR="$( cd -- "$(dirname "${0}")" >/dev/null 2>&1 ; pwd -P )"

source ${ROOT_DIR}/env.sh ${ROOT_DIR}
source ${ROOT_DIR}/certs.sh ${ROOT_DIR}
source ${ROOT_DIR}/helpers.sh

ACTION=${1}
INSTALL_REPO_URL=$(get_install_repo_url) ;

# Login as admin into tsb
#   args:
#     (1) organization
function login_tsb_admin {
  expect <<DONE
  spawn tctl login --username admin --password admin --org ${1}
  expect "Tenant:" { send "\\r" }
  expect eof
DONE
}

# Patch OAP refresh rate of control plane
#   args:
#     (1) cluster profile/name
function patch_oap_refresh_rate_cp {
  OAP_PATCH='{"spec":{"components":{"oap":{"streamingLogEnabled":true,"kubeSpec":{"deployment":{"env":[{"name":"SW_CORE_PERSISTENT_PERIOD","value":"5"}]}}}}}}'
  kubectl --context ${1} -n istio-system patch controlplanes controlplane --type merge --patch ${OAP_PATCH}
}


if [[ ${ACTION} = "install" ]]; then

  MP_CLUSTER_CONTEXT=$(get_mp_minikube_profile) ;
  MP_OUTPUT_DIR=$(get_mp_output_dir) ;

  # Login again as tsb admin in case of a session time-out
  kubectl config use-context ${MP_CLUSTER_CONTEXT} ;
  login_tsb_admin tetrate ;

  export TSB_API_ENDPOINT=$(kubectl --context ${MP_CLUSTER_CONTEXT} get svc -n tsb envoy --output jsonpath='{.status.loadBalancer.ingress[0].ip}') ;
  export TSB_INSTALL_REPO_URL=${INSTALL_REPO_URL}

  CP_COUNT=$(get_cp_count)
  CP_INDEX=0
  while [[ ${CP_INDEX} -lt ${CP_COUNT} ]]; do
    CP_CLUSTER_CONTEXT=$(get_cp_minikube_profile_by_index ${CP_INDEX}) ;
    CP_CLUSTER_NAME=$(get_cp_name_by_index ${CP_INDEX}) ;
    CP_CONFIG_DIR=$(get_cp_config_dir ${CP_INDEX}) ;
    CP_OUTPUT_DIR=$(get_cp_output_dir ${CP_INDEX}) ;
    print_info "Start installation of tsb control plane in cluster ${CP_CLUSTER_NAME} (kubectl context ${CP_CLUSTER_CONTEXT})"

    # Generate a service account private key for the active cluster
    #   REF: https://docs.tetrate.io/service-bridge/1.6.x/en-us/setup/self_managed/onboarding-clusters#using-tctl-to-generate-secrets
    kubectl config use-context ${MP_CLUSTER_CONTEXT} ;
    tctl install cluster-service-account --cluster ${CP_CLUSTER_NAME} > ${CP_OUTPUT_DIR}/cluster-service-account.jwk ;

    # Create control plane secrets
    #   REF: https://docs.tetrate.io/service-bridge/1.6.x/en-us/setup/self_managed/onboarding-clusters#using-tctl-to-generate-secrets
    kubectl config use-context ${MP_CLUSTER_CONTEXT} ;
    tctl install manifest control-plane-secrets \
      --cluster ${CP_CLUSTER_NAME} \
      --cluster-service-account="$(cat ${CP_OUTPUT_DIR}/cluster-service-account.jwk)" \
      --elastic-ca-certificate="$(cat ${MP_OUTPUT_DIR}/es-certs.pem)" \
      --management-plane-ca-certificate="$(cat ${MP_OUTPUT_DIR}/mp-certs.pem)" \
      --xcp-central-ca-bundle="$(cat ${MP_OUTPUT_DIR}/xcp-central-ca-certs.pem)" \
      > ${CP_OUTPUT_DIR}/controlplane-secrets.yaml ;

    # Generate controlplane.yaml by inserting the correct mgmt plane API endpoint IP address
    envsubst < ${CP_CONFIG_DIR}/controlplane-template.yaml > ${CP_OUTPUT_DIR}/controlplane.yaml ;

    # bootstrap cluster with self signed certificate that share a common root certificate
    #   REF: https://docs.tetrate.io/service-bridge/1.6.x/en-us/setup/self_managed/onboarding-clusters#intermediate-istio-ca-certificates
    generate_istio_cert ${CP_CLUSTER_NAME} ;
    CERTS_BASE_DIR=$(get_certs_base_dir) ;

    if ! kubectl --context ${CP_CLUSTER_CONTEXT} get ns istio-system &>/dev/null; then
      kubectl --context ${CP_CLUSTER_CONTEXT} create ns istio-system ; 
    fi
    if ! kubectl --context ${CP_CLUSTER_CONTEXT} -n istio-system get secret cacerts &>/dev/null; then
      kubectl --context ${CP_CLUSTER_CONTEXT} create secret generic cacerts -n istio-system \
        --from-file=${CERTS_BASE_DIR}/${CP_CLUSTER_NAME}/ca-cert.pem \
        --from-file=${CERTS_BASE_DIR}/${CP_CLUSTER_NAME}/ca-key.pem \
        --from-file=${CERTS_BASE_DIR}/${CP_CLUSTER_NAME}/root-cert.pem \
        --from-file=${CERTS_BASE_DIR}/${CP_CLUSTER_NAME}/cert-chain.pem ;
    fi

    # Deploy operators
    #   REF: https://docs.tetrate.io/service-bridge/1.6.x/en-us/setup/self_managed/onboarding-clusters#deploy-operators
    kubectl config use-context ${MP_CLUSTER_CONTEXT} ;
    login_tsb_admin tetrate ;
    tctl install manifest cluster-operators --registry ${INSTALL_REPO_URL} > ${CP_OUTPUT_DIR}/clusteroperators.yaml ;

    # Applying operator, secrets and control plane configuration
    kubectl --context ${CP_CLUSTER_CONTEXT} apply -f ${CP_OUTPUT_DIR}/clusteroperators.yaml ;
    kubectl --context ${CP_CLUSTER_CONTEXT} apply -f ${CP_OUTPUT_DIR}/controlplane-secrets.yaml ;
    while ! kubectl --context ${CP_CLUSTER_CONTEXT} get controlplanes.install.tetrate.io &>/dev/null; do sleep 1; done ;
    kubectl --context ${CP_CLUSTER_CONTEXT} apply -f ${CP_OUTPUT_DIR}/controlplane.yaml ;
    print_info "Bootstrapped installation of tsb control plane in cluster ${CP_CLUSTER_NAME} (kubectl context ${CP_CLUSTER_CONTEXT})"
    CP_INDEX=$((CP_INDEX+1))
  done


  CP_COUNT=$(get_cp_count)
  CP_INDEX=0
  while [[ ${CP_INDEX} -lt ${CP_COUNT} ]]; do
    CP_CLUSTER_CONTEXT=$(get_cp_minikube_profile_by_index ${CP_INDEX}) ;
    print_info "Wait installation of tsb control plane in cluster ${CP_CLUSTER_NAME} to finish (kubectl context ${CP_CLUSTER_CONTEXT})"

    # Wait for the control and data plane to become available
    kubectl --context ${CP_CLUSTER_CONTEXT} wait deployment -n istio-system tsb-operator-control-plane --for condition=Available=True --timeout=600s ;
    kubectl --context ${CP_CLUSTER_CONTEXT} wait deployment -n istio-gateway tsb-operator-data-plane --for condition=Available=True --timeout=600s ;
    while ! kubectl --context ${CP_CLUSTER_CONTEXT} get deployment -n istio-system edge &>/dev/null; do sleep 5; done ;
    kubectl --context ${CP_CLUSTER_CONTEXT} wait deployment -n istio-system edge --for condition=Available=True --timeout=600s ;
    kubectl --context ${CP_CLUSTER_CONTEXT} get pods -A ;

    # Apply OAP patch for more real time update in the UI (Apache SkyWalking demo tweak)
    patch_oap_refresh_rate_cp ${CP_CLUSTER_CONTEXT} ;

    print_info "Finished installation of tsb control plane in cluster ${CP_CLUSTER_NAME} (kubectl context ${CP_CLUSTER_CONTEXT})"
    CP_INDEX=$((CP_INDEX+1))
  done

  exit 0
fi

if [[ ${ACTION} = "uninstall" ]]; then

  CP_COUNT=$(get_cp_count)
  CP_INDEX=0
  while [[ ${CP_INDEX} -lt ${CP_COUNT} ]]; do
    CP_CLUSTER_CONTEXT=$(get_cp_minikube_profile_by_index ${CP_INDEX}) ;
    CP_CLUSTER_NAME=$(get_cp_name_by_index ${CP_INDEX}) ;
    print_info "Start removing installation of tsb control plane in cluster ${CP_CLUSTER_NAME} (kubectl context ${CP_CLUSTER_CONTEXT})"

    # Put operators to sleep
    for NS in tsb istio-system istio-gateway xcp-multicluster cert-manager ; do
      kubectl --context ${CP_CLUSTER_CONTEXT} get deployments -n ${NS} -o custom-columns=:metadata.name \
        | grep operator | xargs -I {} kubectl --context ${CP_CLUSTER_CONTEXT} scale deployment {} -n ${NS} --replicas=0 ; 
    done

    sleep 5 ;

    # Clean up namespace specific resources
    for NS in tsb istio-system istio-gateway xcp-multicluster cert-manager ; do
      kubectl --context ${CP_CLUSTER_CONTEXT} get deployments -n ${NS} -o custom-columns=:metadata.name \
        | grep operator | xargs -I {} kubectl --context ${CP_CLUSTER_CONTEXT} delete deployment {} -n ${NS} --timeout=10s --wait=false ;
      sleep 5 ;
      kubectl --context ${CP_CLUSTER_CONTEXT} delete --all deployments -n ${NS} --timeout=10s --wait=false ;
      kubectl --context ${CP_CLUSTER_CONTEXT} delete --all jobs -n ${NS} --timeout=10s --wait=false ;
      kubectl --context ${CP_CLUSTER_CONTEXT} delete --all statefulset -n ${NS} --timeout=10s --wait=false ;
      kubectl --context ${CP_CLUSTER_CONTEXT} get deployments -n ${NS} -o custom-columns=:metadata.name \
        | grep operator | xargs -I {} kubectl --context ${CP_CLUSTER_CONTEXT} patch deployment {} -n ${NS} --type json \
        --patch='[ { "op": "remove", "path": "/metadata/finalizers" } ]' ;
      kubectl --context ${CP_CLUSTER_CONTEXT} delete --all deployments -n ${NS} --timeout=10s --wait=false ;
      sleep 5 ;
      kubectl --context ${CP_CLUSTER_CONTEXT} delete namespace ${NS} --timeout=10s --wait=false ;
    done 

    # Clean up cluster wide resources
    kubectl --context ${CP_CLUSTER_CONTEXT} get mutatingwebhookconfigurations -o custom-columns=:metadata.name \
      | xargs -I {} kubectl --context ${CP_CLUSTER_CONTEXT} delete mutatingwebhookconfigurations {}  --timeout=10s --wait=false ;
    kubectl --context ${CP_CLUSTER_CONTEXT} get crds -o custom-columns=:metadata.name | grep "cert-manager\|istio\|tetrate" \
      | xargs -I {} kubectl --context ${CP_CLUSTER_CONTEXT} delete crd {} --timeout=10s --wait=false ;
    kubectl --context ${CP_CLUSTER_CONTEXT} get validatingwebhookconfigurations -o custom-columns=:metadata.name \
      | xargs -I {} kubectl --context ${CP_CLUSTER_CONTEXT} delete validatingwebhookconfigurations {} --timeout=10s --wait=false ;
    kubectl --context ${CP_CLUSTER_CONTEXT} get clusterrole -o custom-columns=:metadata.name | grep "cert-manager\|istio\|tsb\|xcp" \
      | xargs -I {} kubectl --context ${CP_CLUSTER_CONTEXT} delete clusterrole {} --timeout=10s --wait=false ;
    kubectl --context ${CP_CLUSTER_CONTEXT} get clusterrolebinding -o custom-columns=:metadata.name | grep "cert-manager\|istio\|tsb\|xcp" \
      | xargs -I {} kubectl --context ${CP_CLUSTER_CONTEXT} delete clusterrolebinding {} --timeout=10s --wait=false ;

    # Cleanup custom resource definitions
    kubectl --context ${CP_CLUSTER_CONTEXT} get crds -o custom-columns=:metadata.name | grep "cert-manager\|istio\|tetrate" \
      | xargs -I {} kubectl --context ${CP_CLUSTER_CONTEXT} delete crd {} --timeout=10s --wait=false ;
    sleep 5 ;
    kubectl --context ${CP_CLUSTER_CONTEXT} get crds -o custom-columns=:metadata.name | grep "cert-manager\|istio\|tetrate" \
      | xargs -I {} kubectl --context ${CP_CLUSTER_CONTEXT} patch crd {} --type json --patch='[ { "op": "remove", "path": "/metadata/finalizers" } ]' ;
    sleep 5 ;
    kubectl --context ${CP_CLUSTER_CONTEXT} get crds -o custom-columns=:metadata.name | grep "cert-manager\|istio\|tetrate" \
      | xargs -I {} kubectl --context ${CP_CLUSTER_CONTEXT} delete crd {} --timeout=10s --wait=false ;

    # Clean up pending finalizer namespaces
    for NS in tsb istio-system istio-gateway xcp-multicluster cert-manager ; do
      kubectl --context ${CP_CLUSTER_CONTEXT} get namespace ${NS} -o json \
        | tr -d "\n" | sed "s/\"finalizers\": \[[^]]\+\]/\"finalizers\": []/" \
        | kubectl --context ${CP_CLUSTER_CONTEXT} replace --raw /api/v1/namespaces/${NS}/finalize -f - ;
    done

    sleep 10 ;

    print_info "Finished removing installation of tsb control plane in cluster ${CP_CLUSTER_NAME} (kubectl context ${CP_CLUSTER_CONTEXT})"
    CP_INDEX=$((CP_INDEX+1))
  done

  exit 0
fi


echo "Please specify one of the following action:"
echo "  - install"
echo "  - uninstall"
exit 1
