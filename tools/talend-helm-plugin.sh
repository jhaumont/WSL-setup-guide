#!/usr/bin/env bash

set -eo pipefail
set -o allexport
#set -x

TALEND_LOCAL_PATH=${HELM_HOME:-$(helm home)}/cache/plugins/talend
LOCAL_ENV_VALUES=$TALEND_LOCAL_PATH/environment.sh
PROVISIONER_DIR=$HELM_PLUGIN_DIR/provisioner
PROVISIONER_EXEC=$PROVISIONER_DIR/tpcli
HELM_README_HELPER_DIR=$HELM_PLUGIN_DIR/helm-readme-helper
HELM_README_HELPER_EXEC=$HELM_README_HELPER_DIR/helm-readme-helper
MCSA_DIR=$HELM_PLUGIN_DIR/mcsa
MCSA_BOOTSTRAP_EXEC=$MCSA_DIR/kubemcsa

ANSIBLE_VIRTUALENV=${ANSIBLE_VIRTUALENV:-talend-ansible}
ANSIBLE_EXEC=ansible-playbook

CURRENT_FOLDER=$(pwd)

trap cleanup EXIT

cleanup(){
  # return to current folder in case of an exit in a different folder
  cd $CURRENT_FOLDER
  # virtualenv deactivation
  deactivate &> /dev/null || true #ignors the error
}

# -----------------------------------------------------------------------------
# Print plugin version
version() {
  echo "$( helm plugin list | awk -v col=2 '/^talend.*/{print $col}' )"
}

init(){
  shift

  if [ "$1" = "--help" ];then

    echo "Initialise your local environment :"
    echo "  * setup the plugin environment variables"
    echo "  * setup the 2 Talend Helm registries"
    echo "  * setup the 2 Talend Docker access secrets"
    echo "  * check Ansible setup"
    echo "  * setup Traefik"
    echo "  * setup Multicluster Service Account (MCSA)"
    echo
    echo "Usage:"
    echo "  helm talend init [options] [-hc <path to talend helm-charts clone>] [-hcd <path to talend helm-charts-deploy clone>]"
    echo
    echo "Options:"
    echo "  -hc       optional path to your helm-charts clone folder"
    echo "  -hcd      optional path to your helm-charts-deploy clone folder"
    echo "  --help    help for init"
    echo
    if [ -e "$LOCAL_ENV_VALUES" ];then
      echo "Your current local environment setup [$LOCAL_ENV_VALUES] is:"
      xargs -I % echo '    %' < "$LOCAL_ENV_VALUES"
    fi
  else
    READLINK_CMD=readlink
    if [ "${OSTYPE:0:6}" == "darwin" ]; then
      # check if readlink is installed
      if [ ! $(which greadlink) ]; then
        echo
        read -r -p  'CoreUtils are not installed on your OS - do you want to install coreutils via brew? (y/n) : ' install_coreutils
        if [ "$install_coreutils" = "y" ]; then
          brew install coreutils
        else
          echo 'Aborting helm talend init'
          exit 1
        fi
      fi
      READLINK_CMD=greadlink
    fi
    parseInitArguments "$@"
    #checking k8s is reachable and helm too
    helmCheck=$(helm version 2>&1) && RES=$? || RES=$?
    if [ $RES -ne 0 ];then
      echo -e "${RED}Please make sure you have a running Kubernetes cluster and Helm is properly installed.${NC}"
      echo "The \`helm version\` command should not fail."
      echo -e "${RED}$helmCheck${NC}"
      exit 0
    fi
    mkdir -p "$TALEND_LOCAL_PATH"
    if [ -e "$LOCAL_ENV_VALUES" ] ;then
      echo
      echo "You already have a local environment setup [$LOCAL_ENV_VALUES]:"
      echo
      xargs -I % echo '    %' < "$LOCAL_ENV_VALUES"
      echo
      read -r -p  'Do you want to modify it? (y/n) : ' modifyEnv
    fi
    #ask for all the config
    if [ -z "$modifyEnv" ] || [ "$modifyEnv" = "Y" ] || [ "$modifyEnv" = "y" ]; then
      echo
      echo "Please provide the following parameters for launching your charts locally or in the dev cluster:"
      echo "The values in parenthesis are precomputed values and you can just type enter to accept them."
      echo
      #ask for helm charts repo
      read -r -p  " - please provide the path to your Talend/helm-charts local copy ($HELM_CHARTS_PATH): " input
      #remove apostrophe from the input value
      eval helm_charts_path=${input:-$HELM_CHARTS_PATH}
      helm_charts_path=$($READLINK_CMD -f $helm_charts_path)

      #ask for helm-charts-deploy path
      HELM_CHARTS_DEPLOY_PATH=$($READLINK_CMD -f ${HELM_CHARTS_DEPLOY_PATH:-$helm_charts_path/../helm-charts-deploy})
      read -r -p  " - please provide the path to your Talend/helm-charts-deploy local copy ($HELM_CHARTS_DEPLOY_PATH): " input
      eval helm_charts_deploy_path=${input:-$HELM_CHARTS_DEPLOY_PATH}
      helm_charts_deploy_path=$($READLINK_CMD -f $helm_charts_deploy_path)

      #ask for tiller namespace
      if [ -z "$LOCAL_TILLER_NAMESPACE" ];then
        tiller_ns=$(kubectl get pods --selector=name=tiller --all-namespaces -o jsonpath --template={.items...metadata.namespace})
      else
        tiller_ns=$LOCAL_TILLER_NAMESPACE
      fi
      read -r -p  " - enter the name of the local Helm tiller namespace ($tiller_ns) : " input
      tiller_ns=${input:-$tiller_ns}
      #ask for local namespace
      if [ -z "$LOCAL_NAMESPACE" ];then
        ns=$(kubectl config view --minify --output 'jsonpath={..namespace}')
        if [ "$ns" = "" ];then
          ns="default"
        fi
      else
        ns=$LOCAL_NAMESPACE
      fi
      read -r -p  " - enter the name of the local namespace ($ns) : " input
      ns=${input:-$ns}
      #get the team namespace and host for hybrid deployments
      while true
      do
        read -r -p  " - enter the team namespace, one of those
      [api, arch, tpd, esb, lab, qa, sre, tdc, tdp, tdq, tds, tmc, tpsvc] ($REMOTE_NAMESPACE): " input
        teamNamespace=${input:-$REMOTE_NAMESPACE}
        if [[ "$teamNamespace" = "" ]]; then
          echo -e "${RED}     Error: You must specify a team namespace. Please try again!${NC}"
        else
          break
        fi
      done
      teamHost="$teamNamespace.dev.datapwn.com"
      local_env_values=( \
        HELM_CHARTS_DEPLOY_PATH=$helm_charts_deploy_path \
        LOCAL_TILLER_NAMESPACE=$tiller_ns \
        LOCAL_NAMESPACE=$ns \
        REMOTE_NAMESPACE=$teamNamespace \
        REMOTE_HOST=$teamHost \
        HELM_CHARTS_PATH=$helm_charts_path \
      )

      ( IFS=$'\n' && echo "${local_env_values[*]}" ) > "$LOCAL_ENV_VALUES"
      # shellcheck disable=SC1090
      source "$LOCAL_ENV_VALUES"
    fi
    checkInstall
    checkHelmSetup
    checkMCSA
  fi
}

parseInitArguments(){
  while [ $# -gt 0 ]
  do
    #echo "args=$@"
    key="$1"

    case $key in
      -hc)
        HELM_CHARTS_PATH=$($READLINK_CMD -f $2)
        ;;
      -hcd)
        HELM_CHARTS_DEPLOY_PATH=$($READLINK_CMD -f $2)
        ;;
    esac
    shift # past argument
  done
}

generate_table(){
  shift
  if [ $# -lt 1 ] || [ "$1" = "--help" ]; then
    echo
    echo "Parses a Helm values file and prints to stdout a documented table which can be copied into the README.md file"
    echo
    echo "Usage:"
    echo "  helm talend generate-table <path-to-values.yaml>"
    echo
    echo "Options:"
    echo "  --help    help for generate-table"
  else
    $HELM_README_HELPER_EXEC generate "$1"
  fi
}

env(){
  shift
  if [ "$1" = "--help" ]; then
    echo
    echo "Display some information about your local setup"
    echo
    echo "Usage:"
    echo "  helm talend env [options]"
    echo
    echo "Options:"
    echo "  --help    help for env"
  else
    showenv
  fi
}

showenv(){
  echo
  echo "Your current local environment setup [$LOCAL_ENV_VALUES] is:"
  echo
  xargs -I % echo '    %' < "$LOCAL_ENV_VALUES"
}

reset(){
  shift
  if [ "$1" = "--help" ]; then
    echo
    echo "Reset your local environment :"
    echo "  * delete the 2 Talend Docker access secrets"
    echo "  * uninstall Traefik"
    echo "  * uninstall Multicluster Service Account (MCSA)"
    echo "  * remove Talend Helm registries"
    echo "  * remove the plugin environment variables"
    echo
    echo "Usage:"
    echo "  helm talend reset"
    echo
    echo "Options:"
    echo "  --help    help for reset"
  else
    echo "checking your Kubernetes cluster setup..."
    k8sServerName=$(kubectl config view --minify=true -o jsonpath='{.clusters[0].cluster.server}')
    k8sContext=$(kubectl config view --minify=true -o jsonpath='{.current-context}')
    k8sNamespace=$(kubectl config view --minify --output 'jsonpath={..namespace}')
    if [ "$k8sNamespace" = "" ];then
      k8sNamespace="default"
    fi
    echo
    echo -e "Current Kubernetes context: ${BLUE}${BOLD}$k8sContext${NOBOLD}${NC}"
    echo -e "Current Kubernetes namespace: ${BLUE}${BOLD}$k8sNamespace${NOBOLD}${NC}"
    echo
    if [[ "$k8sServerName" =~ ".eks." ]] || [[ "$k8sServerName" =~ ".azmk8s." ]] ;then
      echo -e "${RED}You are currently connected to a remote cluster [$k8sContext]${NC}"
      echo -e "${RED}You need to set context on your local DEV cluster before running this command${NC}"
      exit 1
    fi

    #check that talend-docker-registry secrets is present
    kubectl get secret talend-docker-registry  > /dev/null 2>&1 && RES=$? || RES=$?
    talendDockerRegistry=$RES
    #check that talend-registry secrets is present
    kubectl get secret talend-registry  > /dev/null 2>&1 && RES=$? || RES=$?
    talendRegistry=$RES

    if [ $talendDockerRegistry -eq 0 ]; then
      read -r -p 'Do you want to delete Kubernetes secret talend-docker-registry? (y/n) : ' deleteSecrets
      if [ "$deleteSecrets" = "y" ]; then
        kubectl delete secret talend-docker-registry
        echo
        printf "talend-docker-registry secret deleted                 $CHECK\n"
      fi
    fi

    if [ $talendRegistry -eq 0 ]; then
      read -r -p 'Do you want to delete Kubernetes secret talend-registry? (y/n) : ' deleteSecrets
      if [ "$deleteSecrets" = "y" ]; then
        kubectl delete secret talend-registry
        echo
        printf "talend-registry secret deleted                        $CHECK\n"
      fi
    fi

    #check for traefik
    if allSvcs=$(kubectl get svc --all-namespaces -o name); then
      echo "$allSvcs" | grep traefik > /dev/null 2>&1 && RES=$? || RES=$?
      if [ $RES -eq 0 ]; then
        read -r -p 'Traefik is installed in your cluster. Do you want to uninstall it? (y/n) : ' deleteTraefik
        if [ "$deleteTraefik" = "y" ]; then
          if helmUninstall=$(helm delete traefik --purge 2>&1); then
            printf "Traefik successfully uninstalled from your cluster    $CHECK\n"
          else
            printf "${RED}Traefik removal failed                          $RED_CROSS${NC}"
            echo -e "${RED}$helmUninstall${NC}"
          fi
        fi
      fi
    fi

    #check for mcsa
    if mcsaSvcs=$(kubectl get svc -n multicluster-service-account-webhook -o name); then
      echo "$mcsaSvcs" | grep service-account-import > /dev/null 2>&1 && RES=$? || RES=$?
      if [ $RES -eq 0 ]; then
        read -r -p 'Do you want to delete Multicluster Service Account? (y/n) : ' deleteMCSA
        if [ "$deleteMCSA" = "y" ]; then
          echo
          if mcsaUninstall=$(kubectl delete -f $MCSA_DIR/install.yaml 2>&1); then
            printf "Multicluster Service Account resources deleted        $CHECK\n"
            kubectl label namespace $LOCAL_NAMESPACE multicluster-service-account-
            printf "Multicluster Service Account label removed            $CHECK\n"
          else
            printf "${RED}Multicluster Service Account resources removal failed $RED_CROSS${NC}"
            echo -e "${RED}$mcsaUninstall${NC}"
          fi
        fi
      fi
    fi

    #remove Talend Helm registries
    read -r -p "Do you want to remove Talend Helm registries? (y/n) : " deleteTlndHelmReg
    if [ "$deleteTlndHelmReg" = "y" ]; then
      helm repo remove talend > /dev/null
      helm repo remove talend-incubator > /dev/null
      printf "Talend Helm registries removed                        $CHECK\n"
    fi
    
    #remove plugin env file
    read -r -p "Do you want to reset your local environment variables ($LOCAL_ENV_VALUES)? (y/n) : " resetEnv
    if [ "$resetEnv" = "y" ]; then
      /bin/rm -rf $TALEND_LOCAL_PATH
      printf "Plugin environment deleted                            $CHECK\n"
    fi
  fi
}

# -----------------------------------------------------------------------------
# usage
usage() {
cat << EOF
Talend plugin for creating new charts and deploying complete stacks

To begin working with the plugin, run the 'helm talend init' command:

  $ helm talend init [path to talend helm-chart repository]

Usage:
  helm talend [command]

Available commands:
  create                  create a new Helm chart
  delete (alias: rm)      delete all releases belonging to a stack (set of helm charts) in K8s
  deploy (alias: apply)   deploy or update a stack (set of helm charts) to K8s
  env                     display your local setup
  generate-table          generate markdown table describing all properties defined in a values file
  init                    initialize your local environment
  stacks                  list available stacks
  list                    list the deployed stacks in the current cluster
  provision               create account/users
  reset                   reset your local environment
  version                 print plugin version

Options:
  --help                  help for the Talend Helm plugin

Use "helm talend [command] --help" for more information about a command.
EOF

  exit
}


# -----------------------------------------------------------------------------
# main function

main() {
  if [ -e "$LOCAL_ENV_VALUES" ];then
    # shellcheck disable=SC1090
    source "$LOCAL_ENV_VALUES"
  fi

  # shellcheck source=./talend-helm-stack.sh
  # source `which virtualenvwrapper.sh`
  source "$HELM_PLUGIN_DIR/talend-helm-stack-common.sh"
  source "$HELM_PLUGIN_DIR/talend-helm-stack-ansible.sh"

  #parse arguments
  if [[ $# != 0 ]]
  then
    # shellcheck source=./talend-helm-create.sh
    source "$HELM_PLUGIN_DIR/talend-helm-create.sh"
    case "$1" in
      init) init "$@";;
      create) create_chart "$2";;
      list) listDeployedStacks "$@";;
      stacks) listStacks "$@";;
      apply|deploy) apply "$@";;
      delete|rm) delete "$@";;
      provision) provision "$@";;
      env) env "$@";;
      generate-table) generate_table "$@";;
      reset) reset "$@";;
      version) version "$@";;
      *) echo
         usage;;
    esac
  else
    echo
    usage
  fi

}

main "$@"
