#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Redis Cluster 一键部署脚本 (OT-CONTAINER-KIT redis-operator)
# 使用方式：
#   chmod +x deploy.sh
#   ./deploy.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

OPERATOR_NS="redis-operator"
CLUSTER_NS="redis"
OPERATOR_RELEASE="redis-operator"
OPERATOR_CHART="ot-helm/redis-operator"
OPERATOR_IMAGE_TAG="latest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"

log()  { echo -e "\033[1;32m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m[WARN] $*\033[0m"; }
fail() { echo -e "\033[1;31m[ERR]  $*\033[0m"; exit 1; }

# ── 前置检查 ──────────────────────────────────────────────────────────────────
log "检查依赖工具..."
command -v kubectl >/dev/null || fail "未找到 kubectl，请先安装"
command -v helm    >/dev/null || fail "未找到 Helm，请先安装 (https://helm.sh)"

kubectl cluster-info &>/dev/null || fail "无法连接 Kubernetes 集群，请确保集群已就绪"

# ── 1. Helm 仓库 ──────────────────────────────────────────────────────────────
log "1. 添加 OT-CONTAINER-KIT Helm 仓库..."
helm repo add ot-helm https://ot-container-kit.github.io/helm-charts/ 2>/dev/null || true
helm repo update ot-helm

# ── 2. 命名空间 ───────────────────────────────────────────────────────────────
log "2. 创建命名空间 (${OPERATOR_NS} + ${CLUSTER_NS})..."
kubectl apply -f "${MANIFESTS_DIR}/01-namespace.yaml"

# ── 3. 安装 Redis Operator ────────────────────────────────────────────────────
log "3. 安装 Redis Operator..."
if helm status "${OPERATOR_RELEASE}" -n "${OPERATOR_NS}" &>/dev/null; then
  echo "   Operator 已存在，执行 upgrade..."
  helm upgrade "${OPERATOR_RELEASE}" "${OPERATOR_CHART}" \
    --namespace "${OPERATOR_NS}" \
    --set image.tag="${OPERATOR_IMAGE_TAG}"
else
  helm install "${OPERATOR_RELEASE}" "${OPERATOR_CHART}" \
    --namespace "${OPERATOR_NS}" \
    --set image.tag="${OPERATOR_IMAGE_TAG}" \
    --wait
fi

log "   等待 Operator Pod 就绪..."
kubectl rollout status deployment/redis-operator -n "${OPERATOR_NS}" --timeout=120s

# ── 4. Secrets ────────────────────────────────────────────────────────────────
log "4. 创建密码及 ACL Secrets..."
warn "  生产环境请修改 manifests/02-acl-secret.yaml 和 03-redis-password-secret.yaml 中的密码！"
kubectl apply -f "${MANIFESTS_DIR}/02-acl-secret.yaml"
kubectl apply -f "${MANIFESTS_DIR}/03-redis-password-secret.yaml"

# ── 5. 部署 RedisCluster ──────────────────────────────────────────────────────
log "5. 部署 RedisCluster (3 主 3 从)..."
kubectl apply -f "${MANIFESTS_DIR}/04-redis-cluster.yaml"

log "   等待 Operator 创建 StatefulSet (最长等待 60s)..."
for i in $(seq 1 12); do
  if kubectl get statefulset redis-cluster-leader -n "${CLUSTER_NS}" &>/dev/null; then
    echo "   StatefulSet 已创建。"
    break
  fi
  echo "   第 ${i}/12 次轮询，等待中..."
  sleep 5
done

log "   等待 Leader StatefulSet 就绪 (首次拉取镜像约 3-5 分钟)..."
kubectl rollout status statefulset/redis-cluster-leader   -n "${CLUSTER_NS}" --timeout=360s

log "   等待 Operator 创建 Follower StatefulSet..."
for i in $(seq 1 12); do
  if kubectl get statefulset redis-cluster-follower -n "${CLUSTER_NS}" &>/dev/null; then
    break
  fi
  sleep 5
done

log "   等待 Follower StatefulSet 就绪..."
kubectl rollout status statefulset/redis-cluster-follower -n "${CLUSTER_NS}" --timeout=360s

# ── 6. ServiceMonitor (可选) ──────────────────────────────────────────────────
if kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
  log "6. 检测到 Prometheus Operator，部署 ServiceMonitor..."
  kubectl apply -f "${MANIFESTS_DIR}/05-servicemonitor.yaml"
else
  warn "  未检测到 Prometheus Operator CRD，跳过 ServiceMonitor 部署。"
  warn "  如需监控，请先安装 Prometheus Operator 后手动执行："
  warn "    kubectl apply -f manifests/05-servicemonitor.yaml"
fi

# ── 完成 ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "\033[1;32m✅ 部署完成！\033[0m"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Pod 状态："
kubectl get pods -n "${CLUSTER_NS}" -o wide
echo ""
echo "  PVC 状态："
kubectl get pvc -n "${CLUSTER_NS}"
echo ""
echo "  连接测试 (在另一终端执行)："
echo "    kubectl run redis-test --image=redis:7-alpine --rm -it --restart=Never \\"
echo "      -n ${CLUSTER_NS} -- redis-cli -h redis-cluster-leader -p 6379 -a 123456 CLUSTER INFO"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
