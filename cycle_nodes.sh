#!/bin/sh

asg_name=’<your asg name>’
region=’<your aws region>’


desired=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $asg_name --region $region | jq '.AutoScalingGroups[].DesiredCapacity')

newDesired=$(($desired + $desired))

echo "Updating ASG min to $newDesired and desired to $newDesired"
aws autoscaling update-auto-scaling-group --min-size $newDesired --desired-capacity $newDesired --auto-scaling-group-name $asg_name --region $region

nodes=$(kubectl get nodes --sort-by=.metadata.creationTimestamp | grep ip-10 | awk '{print $1}')

numNodes=$(kubectl get nodes | grep Ready | wc -l)

echo "Waiting for nodes to scale up before draining old nodes"
until [ $numNodes -ge $newDesired ]; do 
    numNodes=$(kubectl get nodes | grep Ready | wc -l)
    echo "$numNodes nodes ready out of $newDesired"
    sleep 10
done

echo "Draining the $desired oldest nodes"
nodes2drain=$(kubectl get nodes --sort-by=.metadata.creationTimestamp | grep ec2.internal | awk '{print $1}' | head -$desired)
kubectl drain $nodes2drain --delete-local-data --ignore-daemonsets 

nodes2kill=$(kubectl get nodes --sort-by=.metadata.creationTimestamp -o wide | grep SchedulingDisabled | awk '{print $6}')

echo "Terminating EC2 Instances"
for n in $nodes2kill; do
    id=$(aws ec2 describe-network-interfaces --filters Name=addresses.private-ip-address,Values=$n --region $region | jq -r '.NetworkInterfaces[].Attachment.InstanceId')
    echo "Terminating instance $id"
    aws ec2 terminate-instances --instance-ids $id --region $region
done

echo "Updating ASG min to 2 and desired to $desired"
aws autoscaling update-auto-scaling-group --min-size 2 --desired-capacity $desired --auto-scaling-group-name $asg_name --region $region

echo "Waiting for instances to terminate"
until [ $numNodes -le $desired ]; do 
    numNodes=$(kubectl get nodes | grep Ready | wc -l)
    echo "$numNodes nodes ready out of $desired"
    sleep 10
done
