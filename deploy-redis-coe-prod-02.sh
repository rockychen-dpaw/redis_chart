#!/bin/bash
isprod=$(kubectl config get-contexts | grep  -E "\*\s+az-coe-prod-02" | wc -l)
if [[ ${isprod} -eq 1 ]]; then
    echo "Kubectl is connected to az-coe-prod-02, begin to deploy redis in prod env"
else
    echo "Kubectl is not connected to az-coe-prod-02, can't deploy redis in prod env"
    exit 1
fi

./deploy.sh  upgrade --values values-prod.yaml -n redis redis ./
