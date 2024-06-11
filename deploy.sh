#!/bin/bash

if [[ "$1" == "uninstall" ]];then
    helm $@
    exit $?
fi
helm_dir="${@: -1}"
set -- "${@:1:$(($#-1))}"

#copy all files to /tmp/_helm_chart_deploy
if [[ -e /tmp/_helm_chart_deploy ]];then
    rm -rf /tmp/_helm_chart_deploy
fi

mkdir /tmp/_helm_chart_deploy

cp -rf ${helm_dir}/* /tmp/_helm_chart_deploy

#remove all comments lines
sed -i -E '/^\s*#[^!]*/d' /tmp/_helm_chart_deploy/templates/*

#remove all comments in a line
sed -i -E 's/#[^!]*$//g' /tmp/_helm_chart_deploy/templates/*

echo "helm $@ /tmp/_helm_chart_deploy"
helm $@ /tmp/_helm_chart_deploy


