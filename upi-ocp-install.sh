#! /bin/bash

echo "CONTROL PLANE PROVISIONING STARTED..."
terraform init 

if [ $(echo $?) != 0 ]; then
	exit
fi

terraform plan

if [ $(echo $?) != 0 ]; then
	exit
fi

terraform apply -auto-approve

if [ $(echo $?) != 0 ]; then
	exit
fi

./openshift-install wait-for bootstrap-complete --dir=ignition-files

if [ $(echo $?) != 0 ]; then
        echo "Timed out waiting for bootstrap to complete. Sometimes it can take more that 30 minutes.
Please ssh to bootstrap VM and run `journalctl -b -f -u bootkube.service` command to track bootstraping process. 
Once it completes, continue cluster provisioning manually:
Destroy bootstrap vm: terraform destroy -target=module.bootstrap -auto-approve
export KUBECONFIG environment variable: export KUBECONFIG=$(pwd)/ignition-files/auth/kubeconfig
delete default ingress controller object: oc delete ingresscontroller default -n openshift-ingress-operator
create customized default ingress controller object: oc create -f ingresscontroller-default.yaml
Create compute nodes: cd worker; terraform apply -auto-approve
Approve any pending CSRs:
oc get csr -o json | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs oc adm certificate approve
		"
		exit
fi

export KUBECONFIG=$(pwd)/ignition-files/auth/kubeconfig

if [ $(oc get ingresscontrollers -n openshift-ingress-operator | awk 'NR>1{print $1}' | wc -l) != 0 ]; then
	for ingress in $(oc get ingresscontrollers -n openshift-ingress-operator | awk 'NR>1{print $1}'); do
		oc delete ingresscontroller $ingress -n openshift-ingress-operator
	done
	oc create -f ingresscontroller-default.yaml
else
	oc create -f ingresscontroller-default.yaml
fi

echo "DESTROYING BOOTSTRAP VM..."

terraform destroy -target=module.bootstrap -auto-approve

if [ $(echo $?) != 0 ]; then
	exit
fi

oc describe ingresscontroller/default -n openshift-ingress-operator

echo "******************************************"

sleep 5

echo "WORKERS PROVISIONING STARTED...\n"

cd worker

terraform init 

if [ $(echo $?) != 0 ]; then
	exit
fi

terraform plan

if [ $(echo $?) != 0 ]; then
	exit
fi

terraform apply -auto-approve

if [ $(echo $?) != 0 ]; then
	exit
fi

echo "Searching for any Pending CSRs"

worker_count=`cat terraform.tfvars | grep worker_count | awk '{print $3}'`

while [ $(oc get csr | grep worker | grep Approved | wc -l) != $worker_count ]; do
	oc get csr -o json | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs oc adm certificate approve
	sleep 3
done

cd ../

./openshift-install wait-for install-complete --dir=ignition-files 2> /dev/null

oc get svc -n openshift-ingress

while [ $(oc get pods -n openshift-ingress | awk 'NR==2{print $2}') != "1/1" ]; do
	oc get pods -n openshift-ingress
	sleep 3
done

oc get pods -n openshift-ingress

echo "Checking Openshift Web Console URL:"
sleep 2
echo "curl -kI https://console-openshift-console.apps.$(oc get dns/cluster -o yaml | grep baseDomain | awk '{print $2}')"

echo "\n"

curl -kI https://console-openshift-console.apps.$(oc get dns/cluster -o yaml | grep baseDomain | awk '{print $2}')

./openshift-install wait-for install-complete --dir=ignition-files
