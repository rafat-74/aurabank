#!/bin/bash
###############################################################################
# AuraBank – Build & Push Docker Images to ECR
# Usage: ./scripts/push_images.sh <env> <region> <account_id> [image_tag]
#
# Example:
#   ./scripts/push_images.sh dev eu-west-1 123456789012 v1.0.0
###############################################################################

set -euo pipefail

ENV="${1:?Usage: $0 <env> <region> <account_id> [image_tag]}"
REGION="${2:?Missing region}"
ACCOUNT_ID="${3:?Missing account_id}"
IMAGE_TAG="${4:-$(git rev-parse --short HEAD 2>/dev/null || echo 'latest')}"

PROJECT="aurabank"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/../.."

# ── Frontend services (require multi-stage Dockerfile check) ──────────────────
FRONTEND_SERVICES=("frontend-customers" "frontend-teller")

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🐳 AuraBank Docker Build & Push"
echo "   ENV:        ${ENV}"
echo "   REGION:     ${REGION}"
echo "   ACCOUNT:    ${ACCOUNT_ID}"
echo "   TAG:        ${IMAGE_TAG}"
echo "   REGISTRY:   ${REGISTRY}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Authenticate to ECR ────────────────────────────────────────────────────────
echo ""
echo "🔐 Logging in to ECR..."
aws ecr get-login-password --region "${REGION}" | \
  docker login --username AWS --password-stdin "${REGISTRY}"
echo "   ✅ ECR login successful"

# ── Helper: Ensure ECR repo exists ────────────────────────────────────────────
ensure_ecr_repo() {
  local repo="${1}"
  if ! aws ecr describe-repositories \
        --region "${REGION}" \
        --repository-names "${repo}" >/dev/null 2>&1; then
    echo "  📦 Creating ECR repo: ${repo}"
    aws ecr create-repository \
      --region "${REGION}" \
      --repository-name "${repo}" >/dev/null
    echo "  ✅ Repo created"
  fi
}

# ── Helper: Check if image tag already exists in ECR ──────────────────────────
ecr_tag_exists() {
  local repo="${1}"
  local tag="${2}"
  aws ecr describe-images \
    --region "${REGION}" \
    --repository-name "${repo}" \
    --image-ids imageTag="${tag}" \
    >/dev/null 2>&1
}

# ── Helper: Push with retry ────────────────────────────────────────────────────
push_with_retry() {
  local image="${1}"
  local max_attempts=3
  local attempt=1
  until docker push "${image}"; do
    if [ "${attempt}" -ge "${max_attempts}" ]; then
      echo "  ❌ Push failed after ${max_attempts} attempts: ${image}"
      return 1
    fi
    echo "  ⚠️  Push failed (attempt ${attempt}/${max_attempts}), retrying in 5s..."
    attempt=$((attempt + 1))
    sleep 5
  done
}

# ── Helper: Update 'latest' tag in ECR via re-tag ─────────────────────────────
retag_latest_in_ecr() {
  local repo="${1}"
  local source_tag="${2}"
  echo "  📤 Updating latest tag in ECR (re-tag from ${source_tag})..."
  local manifest
  manifest=$(aws ecr batch-get-image \
    --region "${REGION}" \
    --repository-name "${repo}" \
    --image-ids imageTag="${source_tag}" \
    --query 'images[].imageManifest' \
    --output text)

  # Delete existing 'latest' first (required when immutable tags are enabled)
  aws ecr batch-delete-image \
    --region "${REGION}" \
    --repository-name "${repo}" \
    --image-ids imageTag=latest \
    >/dev/null 2>&1 || true

  aws ecr put-image \
    --region "${REGION}" \
    --repository-name "${repo}" \
    --image-tag latest \
    --image-manifest "${manifest}" >/dev/null
  echo "  ✅ latest tag updated"
}

# ── Helper: Check if frontend Dockerfile is multi-stage ───────────────────────
check_multistage_dockerfile() {
  local svc_name="${1}"
  local dockerfile="${2}"
  local is_frontend=false
  for fs in "${FRONTEND_SERVICES[@]}"; do
    [ "${fs}" = "${svc_name}" ] && is_frontend=true && break
  done
  if ${is_frontend}; then
    local stage_count
    stage_count=$(grep -ci "^FROM" "${dockerfile}" || true)
    if [ "${stage_count}" -lt 2 ]; then
      echo "  ⚠️  WARNING: ${svc_name} is a frontend service but Dockerfile"
      echo "      has only 1 FROM stage. Consider multi-stage build with"
      echo "      a build stage + nginx serve stage to reduce image size."
    fi
  fi
}

# ── Service definitions ────────────────────────────────────────────────────────
# Format: "service_name:context_path:dockerfile_path"
declare -a SERVICES=(
  "auth-service:${ROOT_DIR}/services/auth-service:${ROOT_DIR}/services/auth-service/Dockerfile"
  "accounts-service:${ROOT_DIR}/services/accounts-service:${ROOT_DIR}/services/accounts-service/Dockerfile"
  "transactions-service:${ROOT_DIR}/services/transactions-service:${ROOT_DIR}/services/transactions-service/Dockerfile"
  "notifications-service:${ROOT_DIR}/services/notifications-service:${ROOT_DIR}/services/notifications-service/Dockerfile"
  "api-gateway:${ROOT_DIR}/services/api-gateway:${ROOT_DIR}/services/api-gateway/Dockerfile"
  "frontend-customers:${ROOT_DIR}/services/frontend-customers:${ROOT_DIR}/services/frontend-customers/Dockerfile"
  "frontend-teller:${ROOT_DIR}/services/frontend-teller:${ROOT_DIR}/services/frontend-teller/Dockerfile"
)

FAILED=()
declare -A BUILD_PIDS    # service_name → background PID
declare -A BUILD_IMAGES  # service_name → full image name
declare -A BUILD_REPOS   # service_name → ECR repo name

# ── Phase 1: Parallel builds ───────────────────────────────────────────────────
echo ""
echo "🔨 Phase 1: Building all services in parallel..."
echo ""

for svc_def in "${SERVICES[@]}"; do
  IFS=':' read -r SVC_NAME CONTEXT DOCKERFILE <<< "${svc_def}"
  REPO="${PROJECT}/${ENV}/${SVC_NAME}"
  FULL_IMAGE="${REGISTRY}/${REPO}:${IMAGE_TAG}"

  BUILD_IMAGES["${SVC_NAME}"]="${FULL_IMAGE}"
  BUILD_REPOS["${SVC_NAME}"]="${REPO}"

  if [ ! -f "${DOCKERFILE}" ]; then
    echo "  ⚠️  Dockerfile not found for ${SVC_NAME}, skipping."
    FAILED+=("${SVC_NAME}")
    continue
  fi

  check_multistage_dockerfile "${SVC_NAME}" "${DOCKERFILE}"

  echo "  🚀 Starting build: ${SVC_NAME}"

  # Build in background with cache-from latest
  (
    docker build \
      --platform linux/amd64 \
      --file "${DOCKERFILE}" \
      --tag "${FULL_IMAGE}" \
      --cache-from "${REGISTRY}/${REPO}:latest" \
      --build-arg ENV="${ENV}" \
      --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --build-arg GIT_SHA="${IMAGE_TAG}" \
      "${CONTEXT}" \
      > "/tmp/build_${SVC_NAME}.log" 2>&1
  ) &

  BUILD_PIDS["${SVC_NAME}"]=$!
done

# ── Wait for all builds and collect results ────────────────────────────────────
echo ""
echo "⏳ Waiting for all builds to complete..."
echo ""

for SVC_NAME in "${!BUILD_PIDS[@]}"; do
  PID="${BUILD_PIDS[$SVC_NAME]}"
  if wait "${PID}"; then
    echo "  ✅ Build succeeded: ${SVC_NAME}"
  else
    echo "  ❌ Build failed:    ${SVC_NAME}"
    echo "  ── Build log ──────────────────────────────"
    cat "/tmp/build_${SVC_NAME}.log" || true
    echo "  ───────────────────────────────────────────"
    FAILED+=("${SVC_NAME}")
  fi
  rm -f "/tmp/build_${SVC_NAME}.log"
done

# ── Phase 2: Sequential push (ECR check + push + tag) ─────────────────────────
echo ""
echo "📤 Phase 2: Pushing images to ECR..."
echo ""

for SVC_NAME in "${!BUILD_IMAGES[@]}"; do
  # Skip services that failed to build
  if printf '%s\n' "${FAILED[@]}" | grep -q "^${SVC_NAME}$"; then
    echo "  ⏭  Skipping push for ${SVC_NAME} (build failed)"
    continue
  fi

  FULL_IMAGE="${BUILD_IMAGES[$SVC_NAME]}"
  REPO="${BUILD_REPOS[$SVC_NAME]}"

  echo "▶ Pushing ${SVC_NAME}..."

  # Fix 1: Ensure ECR repo exists before pushing
  ensure_ecr_repo "${REPO}"

  # Skip push if tag already exists in ECR (immutable tags policy)
  if ecr_tag_exists "${REPO}" "${IMAGE_TAG}"; then
    echo "  ⏭  Tag ${IMAGE_TAG} already exists in ECR, skipping push."
  else
    echo "  📤 Pushing ${IMAGE_TAG}..."
    if push_with_retry "${FULL_IMAGE}"; then
      echo "  ✅ Pushed ${IMAGE_TAG}"
    else
      FAILED+=("${SVC_NAME}")
      continue
    fi
  fi

  # Fix 2: Tag strategy — dev gets latest, staging/prod gets SHA only
  if [ "${ENV}" = "dev" ]; then
    retag_latest_in_ecr "${REPO}" "${IMAGE_TAG}"
  else
    echo "  ℹ️  ENV=${ENV}: skipping latest tag (SHA-only policy for staging/prod)"
  fi

  echo "  ✅ ${SVC_NAME} done"
done

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "✅ All images built and pushed successfully!"
  echo ""
  echo "🚀 To deploy with the new tag, run:"
  echo "   cd envs/${ENV}"
  echo "   terraform apply -var='image_tag=${IMAGE_TAG}' -var-file=terraform.tfvars"
else
  echo "❌ Failed services: ${FAILED[*]}"
  exit 1
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
