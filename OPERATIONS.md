# Redis Cluster 操作手册

## 快速开始（一键脚本）

```bash
chmod +x deploy.sh cleanup.sh
./deploy.sh    # 部署
./cleanup.sh   # 清理 (⚠️ 会永久删除所有数据)
```

---

## 手动分步部署

### 1. 添加 Helm 仓库

```bash
helm repo add ot-helm https://ot-container-kit.github.io/helm-charts/
helm repo update ot-helm
```

### 2. 创建命名空间

```bash
kubectl apply -f manifests/01-namespace.yaml
```

### 3. 安装 Redis Operator

```bash
helm install redis-operator ot-helm/redis-operator \
  --namespace redis-operator \
  --set image.tag=latest \
  --wait
```

验证 Operator：

```bash
kubectl rollout status deployment/redis-operator -n redis-operator --timeout=120s
kubectl get pods -n redis-operator
kubectl get crd | grep redis
```

预期 CRD 列表：

```
redisclusters.redis.redis.opstreelabs.in
redisreplications.redis.redis.opstreelabs.in
redissentinels.redis.redis.opstreelabs.in
redis.redis.redis.opstreelabs.in
```

### 4. 创建 Secrets

> ⚠️ 生产环境请在部署前修改密码，建议使用 Sealed Secrets 或 External Secrets Operator。

```bash
# ACL 配置（用户权限规则）
kubectl apply -f manifests/02-acl-secret.yaml

# default 用户密码（redis-secret）
kubectl apply -f manifests/03-redis-password-secret.yaml
```

### 5. 部署 RedisCluster

```bash
kubectl apply -f manifests/04-redis-cluster.yaml

# 持续观察 Pod 启动（约 3-5 分钟）
kubectl get pods -n redis -w
```

等待 StatefulSet 就绪：

```bash
kubectl rollout status statefulset/redis-cluster-leader   -n redis --timeout=360s
kubectl rollout status statefulset/redis-cluster-follower -n redis --timeout=360s
```

### 6. 部署 ServiceMonitor（可选，需 Prometheus Operator）

```bash
kubectl apply -f manifests/05-servicemonitor.yaml
```

---

## 验证部署

### Pod 状态

```bash
kubectl get pods -n redis -o wide
```

预期（每个 Pod 在不同 Node，READY 为 `2/2`）：

```
NAME                        READY   STATUS    NODE
redis-cluster-leader-0      2/2     Running   node-1
redis-cluster-leader-1      2/2     Running   node-2
redis-cluster-leader-2      2/2     Running   node-3
redis-cluster-follower-0    2/2     Running   node-4
redis-cluster-follower-1    2/2     Running   node-5
redis-cluster-follower-2    2/2     Running   node-6
```

> `2/2` = Redis 容器 + redis-exporter sidecar 均正常运行。

### PVC 状态

```bash
kubectl get pvc -n redis
```

预期 12 个 PVC（6 数据 + 6 nodeConf），均为 `Bound`。

### 反亲和性验证

```bash
kubectl get pods -n redis -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName'
```

### 集群连接测试

```bash
kubectl run redis-test \
  --image=redis:7-alpine --rm -it --restart=Never \
  -n redis \
  -- redis-cli -h redis-cluster-leader -p 6379 -a 123456 CLUSTER INFO
```

预期：`cluster_state:ok`，`cluster_slots_assigned:16384`。

### ACL 验证

```bash
kubectl run redis-acl-test \
  --image=redis:7-alpine --rm -it --restart=Never \
  -n redis \
  -- redis-cli -h redis-cluster-leader -p 6379 -a 123456 ACL LIST
```

### 监控指标验证

```bash
kubectl port-forward pod/redis-cluster-leader-0 9121:9121 -n redis
# 另开终端
curl http://localhost:9121/metrics | grep redis_up
```

---

## 运维操作

### 更新 ACL 配置

修改 `manifests/02-acl-secret.yaml` 后：

```bash
kubectl apply -f manifests/02-acl-secret.yaml
kubectl rollout restart statefulset/redis-cluster-leader   -n redis
kubectl rollout restart statefulset/redis-cluster-follower -n redis
```

### 水平扩容（增加主节点数）

修改 `manifests/04-redis-cluster.yaml` 中的 `clusterSize`：

```yaml
spec:
  clusterSize: 6  # 从 3 扩容到 6
```

```bash
kubectl apply -f manifests/04-redis-cluster.yaml
```

> [!WARNING]
> 扩容前确保有足够可用 Node（硬性反亲和性每个 Pod 独占一个 Node）。

### 升级 Operator

```bash
helm upgrade redis-operator ot-helm/redis-operator \
  --namespace redis-operator \
  --set image.tag=<new-version>
```

### 查看 Operator 日志

```bash
kubectl logs -n redis-operator \
  $(kubectl get pod -n redis-operator -l name=redis-operator \
    -o jsonpath='{.items[0].metadata.name}') -f
```

### 查看 RedisCluster 详情

```bash
kubectl describe rediscluster redis-cluster -n redis
```

---

## 常见问题排查

### Pod 一直 Pending

**原因**：硬性反亲和性无法满足（可用 Node < 6）。

```bash
kubectl describe pod <pod-name> -n redis | grep -A 20 Events
```

解决：增加 Worker Node，或将 `requiredDuringScheduling...` 改为 `preferredDuringScheduling...`。

### PVC 无法绑定

```bash
kubectl describe pvc <pvc-name> -n redis
kubectl get storageclass standard
```

确认 `standard` StorageClass 存在且支持动态制备。

### Cluster 未形成 (cluster_state: fail)

```bash
kubectl logs -n redis-operator <operator-pod-name> -f
kubectl describe rediscluster redis-cluster -n redis
```

### ACL 认证失败 (WRONGPASS)

```bash
kubectl get secret redis-acl-secret -n redis \
  -o jsonpath='{.data.user\.acl}' | base64 -d
```

确认 `user.acl` 中密码与实际使用的密码一致。

### redis-exporter 无法采集指标

```bash
kubectl logs <pod-name> -c redis-exporter -n redis
kubectl get svc -n redis --show-labels | grep redis-cluster
```

---

## 卸载

```bash
./cleanup.sh
```

或手动分步：

```bash
# 1. 删除 RedisCluster
kubectl delete rediscluster redis-cluster -n redis

# 2. 删除 PVC (数据永久清除)
kubectl delete pvc -n redis --all

# 3. 卸载 Operator
helm uninstall redis-operator -n redis-operator

# 4. 删除 CRDs (可选)
kubectl delete crd \
  redisclusters.redis.redis.opstreelabs.in \
  redisreplications.redis.redis.opstreelabs.in \
  redissentinels.redis.redis.opstreelabs.in \
  redis.redis.redis.opstreelabs.in

# 5. 删除命名空间
kubectl delete namespace redis redis-operator
```
