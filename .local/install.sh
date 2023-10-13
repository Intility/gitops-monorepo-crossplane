#!/bin/bash

export MINIKUBE=false

BLUE=$(tput setaf 4)
NORMAL=$(tput sgr0)
BRIGHT=$(tput bold)
COLOR=$BLUE
STAR='🌟 '

printf "\n%s%s%s\n" "$STAR" "$COLOR" "checking for kind or minikube..."
if ! command -v kind &> /dev/null
then
  echo "kind could not be found, checking for minikube..."
  if ! command -v minikube &> /dev/null
  then
    echo "minikube could not be found. Please install minikube or kind and try again."
    exit 1
  else
    export MINIKUBE=true
  fi
fi

if [ $MINIKUBE == true ]
then
  echo "creating cluster with minikube..."
  if ! minikube start --addons ingress
  then
    echo "failed to create minikube cluster. Exiting..."
    exit 1
  fi
else
  echo "creating cluster with kind..."
  if ! kind create cluster --name my-cluster --config .local/kind-config.yaml
  then
    echo "failed to create kind cluster. exiting..."
    exit 1
  fi
fi

if [[ $(kubectl config current-context) != "kind-my-cluster" ]] && [[ $(kubectl config current-context) != "minikube"  ]]
then
  echo "Current context is not kind-my-cluster. Please switch to the correct context and try again."
  exit 1
fi

if [[ $MINIKUBE == false ]]
then
  printf "\n%s%s%s\n" "$STAR" "$COLOR" "installing nginx ingress controller..."
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml || exit 1

fi

printf "\n%s%s%s\n" "$STAR" "$COLOR" "waiting for ingress controller to get ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s

printf "\n%s%s%s\n" "$STAR" "$COLOR" "sleep for 10 seconds to allow ingress controller to get ready..."
sleep 10
printf "\n%s%s%s\n" "$STAR" "$COLOR" "installing argocd..."
kubectl apply -k .local/argo || exit 1

printf "\n%s%s%s\n" "$STAR" "$COLOR" "waiting for argocd to get ready..."
kubectl wait -n argocd \
  --for=condition=ready pod \
  --timeout=90s \
  --selector=app.kubernetes.io/name=argocd-server

printf "\n%s%s%s\n" "$STAR" "$COLOR" "installing crossplane..."
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm install crossplane --namespace crossplane-system \
                        --create-namespace crossplane-stable/crossplane

sleep 10

printf "\n%s%s%s\n" "$STAR" "$COLOR" "waiting for crossplane to get ready..."
kubectl wait --namespace crossplane-system \
             --for=condition=ready pod \
             --selector=app.kubernetes.io/instance=crossplane \
             --timeout=90s

printf "\n%s%s%s\n" "$STAR" "$COLOR" "installing crossplane kubernetes provider..."
cat << EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-kubernetes
spec:
  package: "crossplanecontrib/provider-kubernetes:main"
EOF

printf "\n%s%s%s\n" "$STAR" "$COLOR" "sleeping for 10 seconds..."
sleep 10

SA=$(kubectl -n crossplane-system get sa -o name | grep provider-kubernetes | sed -e 's|serviceaccount\/|crossplane-system:|g')
kubectl create clusterrolebinding provider-kubernetes-admin-binding --clusterrole cluster-admin --serviceaccount="${SA}"

printf "\n%s%s%s\n" "$STAR" "$COLOR" "applying provider config..."
cat << EOF | kubectl apply -f -
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: kubernetes-provider
spec:
  credentials:
    source: InjectedIdentity
EOF

printf "\n%s%s%s\n" "$STAR" "$COLOR" "creating custom resources..."
kubectl apply -k iac/crossplane || exit 1

argo_password=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
argo_host=$(kubectl -n argocd get ingress argocd-server-ingress -o jsonpath="{.spec.rules[0].host}")
argo_path=$(kubectl get ingress -n argocd argocd-server-ingress -o jsonpath="{.spec.rules[0].http.paths[0].path}")
printf "\nArgoCD now available at http://%s%s" "${argo_host:=localhost}" "$argo_path"
printf "\nusername: %sadmin%s" "${BRIGHT}" "${NORMAL}"
printf "\npassword: %s%s%s\n" "${BRIGHT}" "$argo_password" "${NORMAL}"

kubectl apply -k iac/ || exit 1
