#!/bin/bash
isuat=$(kubectl config get-contexts | grep  -E "\*\s+az-aks-oim03" | wc -l)
if [[ ${isuat} -eq 1 ]]; then
    echo "Kubectl is connected to az-aks-oim03, begin to deploy redis in uat env"
else
    echo "Kubectl is not connected to az-aks-oim03, can't deploy redis in uat env"
    exit 1
fi

./deploy.sh  upgrade --values values-uat.yaml -n redis redis ./
