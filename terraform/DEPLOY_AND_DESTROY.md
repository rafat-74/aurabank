# AuraBank Infrastructure — Deploy & Destroy

> **Account:** `816709079108` | **Region:** `us-east-1` | **Env:** `dev`

---

## 🚀 Deploy

```bash
# 1. Bootstrap (مرة واحدة بس)
cd terraform/scripts && ./bootstrap_state.sh dev us-east-1

# 2. Build Lambda zip (مرة واحدة بس)
cd terraform/modules/rds && ./build_lambda.sh

# 3. Init + Apply
cd terraform/envs/dev
terraform init
terraform apply -var-file=terraform.tfvars

# 4. Push Docker Images
cd ../../.. && ./terraform/scripts/push_images.sh dev us-east-1 816709079108 v1.0.0

# 5. Init DB
aws lambda invoke --function-name aurabank-dev-db-init --region us-east-1 /tmp/out.json
cat /tmp/out.json

# 6. Verify services
aws ecs describe-services \
  --cluster aurabank-dev-cluster \
  --services aurabank-dev-api-gateway aurabank-dev-auth-service \
             aurabank-dev-accounts-service aurabank-dev-transactions-service \
             aurabank-dev-notifications-service aurabank-dev-frontend-customers \
             aurabank-dev-frontend-teller \
  --region us-east-1 \
  --query 'services[*].{Name:serviceName,Running:runningCount,Desired:desiredCount}' \
  --output table
```

---

## 🗑️ Destroy

```bash
# 1. افرغ ECR (لازم قبل destroy)
for repo in accounts-service api-gateway auth-service transactions-service \
            notifications-service frontend-customers frontend-teller; do
  IMAGE_IDS=$(aws ecr list-images --repository-name "aurabank/dev/${repo}" \
    --region us-east-1 --query 'imageIds[*]' --output json)
  [ "$IMAGE_IDS" = "[]" ] && continue
  aws ecr batch-delete-image --repository-name "aurabank/dev/${repo}" \
    --image-ids "$IMAGE_IDS" --region us-east-1
done

# 2. Terraform Destroy
cd terraform/envs/dev
terraform destroy -var-file=terraform.tfvars
# لو الـ DynamoDB اتمسحت يدوياً:
# terraform destroy -var-file=terraform.tfvars -lock=false

# 3. امسح S3 State Bucket
BUCKET="aurabank-terraform-state-dev"
for TYPE in Versions DeleteMarkers; do
  aws s3api list-object-versions --bucket "$BUCKET" --region us-east-1 \
    --query "${TYPE}[].{Key:Key,VersionId:VersionId}" --output json | \
    python3 -c "
import sys,json,subprocess
items=json.load(sys.stdin)
if not items: sys.exit(0)
subprocess.run(['aws','s3api','delete-objects','--bucket','$BUCKET',
  '--delete',json.dumps({'Objects':items,'Quiet':True}),'--region','us-east-1'])
print(f'Deleted {len(items)} ${TYPE}')
"
done
aws s3api delete-bucket --bucket "$BUCKET" --region us-east-1 && echo "Bucket deleted"

# 4. امسح DynamoDB
aws dynamodb delete-table --table-name aurabank-terraform-locks-dev --region us-east-1
```

> ⚠️ لو اضطريت تعمل `-lock=false` — الـ terraform بيكتب state جديد في الـ bucket.
> افحص بـ `aws s3api list-object-versions --bucket $BUCKET --region us-east-1 --output json`
> وامسح أي version فاضل يدوياً قبل ما تمسح الـ bucket.
