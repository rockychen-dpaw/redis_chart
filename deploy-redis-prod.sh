#!/bin/bash
isprod=$(kubectl config get-contexts | grep  -E "\*\s+az-aks-prod01" | wc -l)
if [[ ${isprod} -eq 1 ]]; then
    echo "Kubectl is connected to az-aks-prod01, begin to deploy redis in prod env"
else
    echo "Kubectl is not connected to az-aks-prod01, can't deploy redis in prod env"
    exit 1
fi

./deploy.sh  upgrade --values values-prod.yaml -n redis redis ./
