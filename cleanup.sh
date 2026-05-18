#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Redis Cluster 一键清理脚本 (OT-CONTAINER-KIT redis-operator)
# 使用方式：chmod +x cleanup.sh && ./cleanup.sh
# 快速确认：./cleanup.sh --force  (跳过所有确认)
# ⚠️  此脚本会删除所有 PVC，数据将永久清除，请谨慎操作！
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

OPERATOR_NS="redis-operator"
CLUSTER_NS="redis"
OPERATOR_RELEASE="redis-operator"
FORCE=false

# ── 解析参数 ──────────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=true ;;
    --help|-h)
      echo "用法: $0 [--force|-f]"
      echo "  --force, -f    跳过所有确认提示"
      exit 0
      ;;
  esac
done

# ── 颜色和日志 ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${YELLOW}==> $*${NC}"; }
warn()    { echo -e "${RED}[WARN] $*${NC}"; }
info()    { echo -e "${BLUE}[INFO] $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }

confirm() {
  local prompt="${1:-确认继续?}"
  [[ "$FORCE" == "true" ]] && return 0
  read -r -p "${prompt} [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

warn "⚠️  此操作将删除 Redis Cluster 及所有数据 (PVC)，请确认！"
echo ""
echo "将删除的资源："
echo "  • RedisCluster: redis-cluster"
echo "  • Namespace: ${CLUSTER_NS}"
echo "  • Operator: ${OPERATOR_RELEASE}"
echo ""

if ! confirm "输入 Y/y 继续删除，其他任意键退出"; then
  info "已取消。"
  exit 0
fi

echo ""

# ── 1. 删除 ServiceMonitor (若存在) ──────────────────────────────────────────
log "1. 删除 ServiceMonitor (若存在)..."
kubectl delete servicemonitor redis-cluster-monitor -n "${CLUSTER_NS}" --ignore-not-found 2>/dev/null || true

# ── 2. 删除 RedisCluster 资源 ─────────────────────────────────────────────────
log "2. 删除 RedisCluster..."
kubectl delete rediscluster redis-cluster -n "${CLUSTER_NS}" --ignore-not-found

log "   等待 Pod 完全终止 (最长 120s)..."
kubectl wait --for=delete pod \
  -l app=redis-cluster-leader \
  -n "${CLUSTER_NS}" --timeout=120s 2>/dev/null || true
kubectl wait --for=delete pod \
  -l app=redis-cluster-follower \
  -n "${CLUSTER_NS}" --timeout=120s 2>/dev/null || true

# ── 3. 删除 PVC ───────────────────────────────────────────────────────────────
log "3. 删除 PVC (数据将永久清除)..."
PVC_COUNT=$(kubectl get pvc -n "${CLUSTER_NS}" --no-headers 2>/dev/null | wc -l)
if [[ $PVC_COUNT -gt 0 ]]; then
  if confirm "确认删除 ${CLUSTER_NS} 命名空间下全部 PVC（共 ${PVC_COUNT} 个）"; then
    kubectl delete pvc -n "${CLUSTER_NS}" --all --ignore-not-found
    success "$PVC_COUNT 个 PVC 已删除"
  fi
else
  info "无 PVC 需要删除"
fi

# ── 4. 删除 Secrets ───────────────────────────────────────────────────────────
log "4. 删除 Secrets..."
kubectl delete secret \
  redis-acl-secret \
  redis-secret \
  -n "${CLUSTER_NS}" --ignore-not-found 2>/dev/null || true
success "Secrets 已删除"

# ── 5. 卸载 Redis Operator ────────────────────────────────────────────────────
log "5. 卸载 Redis Operator Helm Release..."
if helm status "${OPERATOR_RELEASE}" -n "${OPERATOR_NS}" &>/dev/null 2>&1; then
  helm uninstall "${OPERATOR_RELEASE}" -n "${OPERATOR_NS}"
  success "Operator 已卸载"
else
  info "Operator 不存在，跳过"
fi

# ── 6. 删除 CRDs (可选) ───────────────────────────────────────────────────────
if confirm "是否同时删除 Redis CRDs？(删除后其他命名空间的 Redis 资源也会受影响)"; then
  log "6. 删除 Redis CRDs..."
  kubectl delete crd \
    redisclusters.redis.redis.opstreelabs.in \
    redisreplications.redis.redis.opstreelabs.in \
    redissentinels.redis.redis.opstreelabs.in \
    redis.redis.redis.opstreelabs.in \
    --ignore-not-found 2>/dev/null || true
  success "CRDs 已删除"
else
  info "跳过 CRD 删除。"
fi

# ── 7. 删除命名空间 ───────────────────────────────────────────────────────────
log "7. 删除命名空间 ${CLUSTER_NS}..."
if kubectl get namespace "${CLUSTER_NS}" &>/dev/null; then
  echo "   当前命名空间内剩余资源："
  kubectl get all,pvc,secret,configmap -n "${CLUSTER_NS}" 2>/dev/null || true
  echo ""
  if confirm "确认删除命名空间 ${CLUSTER_NS}？该操作不可恢复"; then
    kubectl delete namespace "${CLUSTER_NS}" --ignore-not-found
    success "命名空间已删除"
  else
    info "跳过 ${CLUSTER_NS} 命名空间删除，如需手动删除：kubectl delete namespace ${CLUSTER_NS}"
  fi
else
  info "命名空间 ${CLUSTER_NS} 不存在，跳过"
fi

log "8. 删除命名空间 ${OPERATOR_NS}..."
if kubectl get namespace "${OPERATOR_NS}" &>/dev/null; then
  echo "   当前命名空间内剩余资源："
  kubectl get all,pvc,secret,configmap -n "${OPERATOR_NS}" 2>/dev/null || true
  echo ""
  if confirm "确认删除命名空间 ${OPERATOR_NS}？该操作不可恢复"; then
    kubectl delete namespace "${OPERATOR_NS}" --ignore-not-found
    success "命名空间已删除"
  else
    info "跳过 ${OPERATOR_NS} 命名空间删除，如需手动删除：kubectl delete namespace ${OPERATOR_NS}"
  fi
else
  info "命名空间 ${OPERATOR_NS} 不存在，跳过"
fi

echo ""
success "清理完成！"
