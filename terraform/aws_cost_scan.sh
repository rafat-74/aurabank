#!/bin/bash
# AWS Full Account Cost Scan
# شغّله عشان تشوف كل حاجة بتكلف فلوس في الـ account

REGION="us-east-1"
S="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "$S"
echo "🖥️  EC2 Instances"
aws ec2 describe-instances --region $REGION \
  --query 'Reservations[*].Instances[*].{ID:InstanceId,Type:InstanceType,State:State.Name,Name:Tags[?Key==`Name`].Value|[0]}' \
  --output table

echo "$S"
echo "💾 EBS Volumes"
aws ec2 describe-volumes --region $REGION \
  --query 'Volumes[*].{ID:VolumeId,SizeGB:Size,Type:VolumeType,State:State}' \
  --output table

echo "$S"
echo "📸 EBS Snapshots (owned by you)"
aws ec2 describe-snapshots --region $REGION --owner-ids self \
  --query 'Snapshots[*].{ID:SnapshotId,SizeGB:VolumeSize,Date:StartTime}' \
  --output table

echo "$S"
echo "🖼️  AMIs (owned by you)"
aws ec2 describe-images --region $REGION --owners self \
  --query 'Images[*].{ID:ImageId,Name:Name,Date:CreationDate}' \
  --output table

echo "$S"
echo "📍 Elastic IPs (~\$3.6/شهر لو مش متربوطة)"
aws ec2 describe-addresses --region $REGION \
  --query 'Addresses[*].{IP:PublicIp,AllocID:AllocationId,Instance:InstanceId,AssocID:AssociationId}' \
  --output table

echo "$S"
echo "🌐 NAT Gateways (~\$32/شهر للواحدة)"
aws ec2 describe-nat-gateways --region $REGION \
  --filter "Name=state,Values=available,pending" \
  --query 'NatGateways[*].{ID:NatGatewayId,State:State,Subnet:SubnetId}' \
  --output table

echo "$S"
echo "🔌 VPC Endpoints - Interface"
aws ec2 describe-vpc-endpoints --region $REGION \
  --filters "Name=vpc-endpoint-type,Values=Interface" \
  --query 'VpcEndpoints[*].{ID:VpcEndpointId,Service:ServiceName,State:State}' \
  --output table

echo "$S"
echo "🌐 VPCs (غير الـ default)"
aws ec2 describe-vpcs --region $REGION \
  --filters "Name=isDefault,Values=false" \
  --query 'Vpcs[*].{ID:VpcId,CIDR:CidrBlock,Name:Tags[?Key==`Name`].Value|[0]}' \
  --output table

echo "$S"
echo "🌉 Network Interfaces غير مستخدمة"
aws ec2 describe-network-interfaces --region $REGION \
  --filters "Name=status,Values=available" \
  --query 'NetworkInterfaces[*].{ID:NetworkInterfaceId,Type:InterfaceType,AZ:AvailabilityZone}' \
  --output table

echo "$S"
echo "⚖️  Load Balancers"
aws elbv2 describe-load-balancers --region $REGION \
  --query 'LoadBalancers[*].{Name:LoadBalancerName,Type:Type,State:State.Code}' \
  --output table

echo "$S"
echo "🎯 Target Groups"
aws elbv2 describe-target-groups --region $REGION \
  --query 'TargetGroups[*].{Name:TargetGroupName,Port:Port,Protocol:Protocol}' \
  --output table

echo "$S"
echo "🗄️  RDS Instances"
aws rds describe-db-instances --region $REGION \
  --query 'DBInstances[*].{ID:DBInstanceIdentifier,Class:DBInstanceClass,Engine:Engine,Status:DBInstanceStatus,StorageGB:AllocatedStorage}' \
  --output table

echo "$S"
echo "📊 RDS Snapshots"
aws rds describe-db-snapshots --region $REGION --snapshot-type manual \
  --query 'DBSnapshots[*].{ID:DBSnapshotIdentifier,DB:DBInstanceIdentifier,SizeGB:AllocatedStorage,Status:Status}' \
  --output table

echo "$S"
echo "🖥️  ECS Clusters & Services"
aws ecs list-clusters --region $REGION --query 'clusterArns' --output table
for cluster in $(aws ecs list-clusters --region $REGION --query 'clusterArns[]' --output text 2>/dev/null); do
  echo "  >> $cluster"
  aws ecs list-services --cluster "$cluster" --region $REGION \
    --query 'serviceArns' --output table
done

echo "$S"
echo "🐳 ECR Repositories"
aws ecr describe-repositories --region $REGION \
  --query 'repositories[*].{Name:repositoryName}' \
  --output table

echo "$S"
echo "⚡ Lambda Functions"
aws lambda list-functions --region $REGION \
  --query 'Functions[*].{Name:FunctionName,Runtime:Runtime,MemoryMB:MemorySize}' \
  --output table

echo "$S"
echo "🌍 CloudFront Distributions"
aws cloudfront list-distributions \
  --query 'DistributionList.Items[*].{ID:Id,Domain:DomainName,Enabled:Enabled,Status:Status}' \
  --output table

echo "$S"
echo "🪣 S3 Buckets"
aws s3api list-buckets \
  --query 'Buckets[*].{Name:Name,Created:CreationDate}' \
  --output table

echo "$S"
echo "🔑 Secrets Manager (~\$0.40/secret/شهر)"
aws secretsmanager list-secrets --region $REGION \
  --query 'SecretList[*].{Name:Name}' \
  --output table

echo "$S"
echo "🔐 KMS Keys - Customer Managed (~\$1/key/شهر)"
for key in $(aws kms list-keys --region $REGION --query 'Keys[*].KeyId' --output text 2>/dev/null); do
  aws kms describe-key --key-id "$key" --region $REGION \
    --query 'KeyMetadata.{ID:KeyId,State:KeyState,Manager:KeyManager,Desc:Description}' \
    --output table 2>/dev/null | grep -v "^$\|^--"
done

echo "$S"
echo "📨 SNS Topics"
aws sns list-topics --region $REGION \
  --query 'Topics[*].TopicArn' --output table

echo "$S"
echo "📬 SQS Queues"
aws sqs list-queues --region $REGION \
  --query 'QueueUrls' --output table

echo "$S"
echo "🔥 WAF WebACLs"
echo "  REGIONAL:"
aws wafv2 list-web-acls --region $REGION --scope REGIONAL \
  --query 'WebACLs[*].{Name:Name,ID:Id}' --output table
echo "  CLOUDFRONT:"
aws wafv2 list-web-acls --region us-east-1 --scope CLOUDFRONT \
  --query 'WebACLs[*].{Name:Name,ID:Id}' --output table 2>/dev/null

echo "$S"
echo "📊 CloudWatch Log Groups"
aws logs describe-log-groups --region $REGION \
  --query 'logGroups[*].{Name:logGroupName,RetentionDays:retentionInDays,StoredMB:storedBytes}' \
  --output table

echo "$S"
echo "🔔 CloudWatch Alarms"
aws cloudwatch describe-alarms --region $REGION \
  --query 'MetricAlarms[*].{Name:AlarmName,State:StateValue}' \
  --output table

echo "$S"
echo "📡 Route53 Hosted Zones"
aws route53 list-hosted-zones \
  --query 'HostedZones[*].{Name:Name,ID:Id,Private:Config.PrivateZone,Records:ResourceRecordSetCount}' \
  --output table

echo "$S"
echo "🔗 IAM Roles (Custom)"
aws iam list-roles \
  --query 'Roles[?!starts_with(Path, `/aws-service-role/`) && Path!=`/aws-reserved/`].{Name:RoleName,Created:CreateDate}' \
  --output table

echo "$S"
echo "📜 IAM Policies (Customer Managed)"
aws iam list-policies --scope Local \
  --query 'Policies[*].{Name:PolicyName,Attached:AttachmentCount}' \
  --output table

echo "$S"
echo "✅ Scan complete!"
