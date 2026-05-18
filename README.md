# Redis Operator 生产环境完整部署操作手册

> **版本说明**：本手册基于 [OT-CONTAINER-KIT/redis-operator](https://github.com/OT-CONTAINER-KIT/redis-operator) 官方示例（`example/v1beta2`），适用于生产环境的 Redis Cluster 模式部署。
>
> - **Redis Operator API 版本**：`redis.redis.opstreelabs.in/v1beta2`
> - **Redis 版本**：`v8`（`clusterVersion: v8`）
> - **镜像 Tag**：`latest`
> - **部署模式**：Redis Cluster（3 主 3 从）

---

## 目录

1. [前置条件](#1-前置条件)
2. [目录结构](#2-目录结构)
3. [步骤一：安装 Redis Operator](#3-步骤一安装-redis-operator)
4. [步骤二：创建命名空间](#4-步骤二创建命名空间)
5. [步骤三：创建密码 Secret](#5-步骤三创建密码-secret)
6. [步骤四：创建 ACL 配置 Secret](#6-步骤四创建-acl-配置-secret)
7. [步骤五：部署 RedisCluster](#7-步骤五部署-rediscluster)
8. [步骤六：配置 Prometheus 监控（可选）](#8-步骤六配置-prometheus-监控可选)
9. [步骤七：验证部署](#9-步骤七验证部署)
10. [配置说明总览](#10-配置说明总览)
11. [生产运维操作](#11-生产运维操作)
12. [常见问题排查](#12-常见问题排查)

---

## 1. 前置条件

| 项目 | 要求 |
|------|------|
| Kubernetes 版本 | ≥ 1.21 |
| Helm | ≥ 3.x |
| kubectl | 与集群版本匹配 |
| StorageClass | `standard`（支持 `ReadWriteOnce`，可动态制备 PV） |
| Prometheus Operator | 若需监控，需预先部署（含 CRD `ServiceMonitor`） |
| 节点数量 | **≥ 6 个 Worker Node**（3主3从，反亲和性强制不同节点）|

> [!IMPORTANT]
> 反亲和性策略为 **`requiredDuringSchedulingIgnoredDuringExecution`（硬性要求）**，集群中可用 Worker Node 数量必须 ≥ 6，否则 Pod 将无法调度（Pending 状态）。

---

## 2. 目录结构

```
redis-operator-deployment/
├── redis-operator-production-manual.md   # 本手册
└── manifests/
    ├── 01-namespace.yaml                 # 命名空间
    ├── 02-acl-secret.yaml                # ACL 配置 Secret
    ├── 03-redis-password-secret.yaml     # 密码 Secret
    ├── 04-redis-cluster.yaml             # RedisCluster CRD（核心）
    └── 05-servicemonitor.yaml            # Prometheus ServiceMonitor
```

---

## 3. 步骤一：安装 Redis Operator

### 3.1 添加 Helm 仓库

```bash
helm repo add ot-helm https://ot-container-kit.github.io/helm-charts/
helm repo update
```

### 3.2 创建 Operator 命名空间

```bash
kubectl create namespace redis-operator
```

### 3.3 安装 Redis Operator

```bash
helm install redis-operator ot-helm/redis-operator \
  --namespace redis-operator \
  --set image.tag=latest \
  --wait
```

### 3.4 验证 Operator 运行状态

```bash
kubectl get pods -n redis-operator
kubectl get crd | grep redis
```

预期输出中应包含以下 CRD：

```
redisclusters.redis.redis.opstreelabs.in
redisreplications.redis.redis.opstreelabs.in
redissentinels.redis.redis.opstreelabs.in
redis.redis.redis.opstreelabs.in
```

---

## 4. 步骤二：创建命名空间

```bash
kubectl apply -f manifests/01-namespace.yaml
```

---

## 5. 步骤三：创建密码 Secret

密码 Secret 用于设置 Redis `default` 用户的认证密码（`123456`）。

**文件**：`manifests/03-redis-password-secret.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: redis-secret
  namespace: redis
  labels:
    app.kubernetes.io/name: redis-cluster
    app.kubernetes.io/managed-by: redis-operator
type: Opaque
stringData:
  password: "123456"
```

```bash
kubectl apply -f manifests/03-redis-password-secret.yaml
```

> [!WARNING]
> 生产环境中**严禁**将明文密码提交至代码仓库。建议使用 [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)、[External Secrets Operator](https://external-secrets.io/) 或 HashiCorp Vault 进行 Secret 管理。

---

## 6. 步骤四：创建 ACL 配置 Secret

ACL Secret 包含完整的 Redis ACL 规则文件，Operator 会将其挂载至 Redis 容器。

**文件**：`manifests/02-acl-secret.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: redis-acl-secret
  namespace: redis
type: Opaque
stringData:
  acl.conf: |
    user default on ~* &* +@all >123456
    user opstree on ~* &* +@all >abc@123
    user buildpiper on ~* &* +@all >abc@123
```

**ACL 规则说明：**

| 用户 | 状态 | key 权限 | channel 权限 | 命令权限 | 密码 |
|------|------|----------|-------------|---------|------|
| `default` | `on` | `~*`（所有 key） | `&*`（所有 channel）| `+@all`（所有命令） | `123456` |
| `opstree` | `on` | `~*`（所有 key） | `&*`（所有 channel）| `+@all`（所有命令） | `abc@123` |
| `buildpiper` | `on` | `~*`（所有 key） | `&*`（所有 channel）| `+@all`（所有命令） | `abc@123` |

```bash
kubectl apply -f manifests/02-acl-secret.yaml
```

---

## 7. 步骤五：部署 RedisCluster

**文件**：`manifests/04-redis-cluster.yaml`

```yaml
apiVersion: redis.redis.opstreelabs.in/v1beta2
kind: RedisCluster
metadata:
  name: redis-cluster
  namespace: redis
  labels:
    app.kubernetes.io/name: redis-cluster
    app.kubernetes.io/version: "v8"
    app.kubernetes.io/managed-by: redis-operator
    environment: production
spec:
  clusterSize: 3
  clusterVersion: v8
  persistenceEnabled: true

  podSecurityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault

  kubernetesConfig:
    image: quay.io/opstree/redis:latest
    imagePullPolicy: IfNotPresent
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 100m
        memory: 128Mi
    redisSecret:
      name: redis-secret
      key: password

  acl:
    secret:
      secretName: redis-acl-secret

  redisExporter:
    enabled: true
    image: quay.io/opstree/redis-exporter:latest
    imagePullPolicy: IfNotPresent
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 100m
        memory: 128Mi
    env:
      - name: REDIS_EXPORTER_INCL_SYSTEM_METRICS
        value: "true"

  redisLeader:
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
                - key: app
                  operator: In
                  values:
                    - redis-cluster-leader
                    - redis-cluster-follower
            topologyKey: "kubernetes.io/hostname"
    containerSecurityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: false
      capabilities:
        drop:
          - ALL

  redisFollower:
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
                - key: app
                  operator: In
                  values:
                    - redis-cluster-follower
                    - redis-cluster-leader
            topologyKey: "kubernetes.io/hostname"
    containerSecurityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: false
      capabilities:
        drop:
          - ALL

  storage:
    volumeClaimTemplate:
      spec:
        storageClassName: standard
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 5Gi
    nodeConfVolume: true
    nodeConfVolumeClaimTemplate:
      spec:
        storageClassName: standard
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
```

**部署命令：**

```bash
kubectl apply -f manifests/04-redis-cluster.yaml

# 观察 Pod 启动过程（约需 2-5 分钟）
kubectl get pods -n redis -w

# 查看 RedisCluster 状态
kubectl describe rediscluster redis-cluster -n redis
```

---

## 8. 步骤六：配置 Prometheus 监控（可选）

> [!NOTE]
> 此步骤需要集群中已安装 Prometheus Operator，并且 Prometheus 的 `serviceMonitorSelector` 包含标签 `release: prometheus`。

**文件**：`manifests/05-servicemonitor.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: redis-cluster-monitor
  namespace: redis
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app: redis-cluster
      redis_setup_type: cluster
  namespaceSelector:
    matchNames:
      - redis
  endpoints:
    - port: redis-exporter
      interval: 30s
      scrapeTimeout: 10s
      path: /metrics
```

```bash
kubectl apply -f manifests/05-servicemonitor.yaml
```

> [!TIP]
> `release: prometheus` 标签需与你的 Prometheus Operator 部署时的 `serviceMonitorSelector` 配置保持一致，查看方式：
> ```bash
> kubectl get prometheus -A -o jsonpath='{.items[*].spec.serviceMonitorSelector}'
> ```

---

## 9. 步骤七：验证部署

### 9.1 检查 Pod 状态

```bash
kubectl get pods -n redis -o wide
```

预期输出（每个 Pod 应在**不同 Node** 上，READY 应为 `2/2`）：

```
NAME                            READY   STATUS    RESTARTS   AGE   NODE
redis-cluster-leader-0          2/2     Running   0          5m    node-1
redis-cluster-leader-1          2/2     Running   0          5m    node-2
redis-cluster-leader-2          2/2     Running   0          5m    node-3
redis-cluster-follower-0        2/2     Running   0          5m    node-4
redis-cluster-follower-1        2/2     Running   0          5m    node-5
redis-cluster-follower-2        2/2     Running   0          5m    node-6
```

> `READY 2/2` = Redis 容器 + redis-exporter sidecar 均正常运行。

### 9.2 验证 PVC 创建

```bash
kubectl get pvc -n redis
```

预期每个 Pod 对应 2 个 PVC（数据卷 + nodeConf 卷），共 12 个。

### 9.3 验证反亲和性

```bash
kubectl get pods -n redis -o custom-columns=\
'NAME:.metadata.name,NODE:.spec.nodeName'
```

### 9.4 连接测试（default 用户）

```bash
kubectl run redis-cli-test \
  --image=redis:7-alpine \
  --rm -it \
  --restart=Never \
  -n redis \
  -- redis-cli \
  -h redis-cluster-leader \
  -p 6379 \
  -a 123456 \
  CLUSTER INFO
```

预期：`cluster_state:ok`，`cluster_slots_assigned:16384`。

### 9.5 验证 ACL 配置

```bash
kubectl run redis-cli-acl \
  --image=redis:7-alpine \
  --rm -it \
  --restart=Never \
  -n redis \
  -- redis-cli \
  -h redis-cluster-leader \
  -p 6379 \
  -a 123456 \
  ACL LIST
```

预期输出应包含三条 user 记录（default、opstree、buildpiper）。

### 9.6 验证监控指标

```bash
kubectl port-forward pod/redis-cluster-leader-0 9121:9121 -n redis
# 新终端
curl http://localhost:9121/metrics | grep redis_up
```

---

## 10. 配置说明总览

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `clusterVersion` | `v8` | Redis 大版本 |
| `clusterSize` | `3` | 主节点数，从节点数相等，共 6 节点 |
| `persistenceEnabled` | `true` | AOF/RDB 持久化 |
| Redis 镜像 | `quay.io/opstree/redis:latest` | 官方镜像 |
| Exporter 镜像 | `quay.io/opstree/redis-exporter:latest` | 监控 sidecar |
| CPU Request/Limit | `100m` | 每个容器（含 exporter） |
| Memory Request/Limit | `128Mi` | 每个容器（含 exporter） |
| `storageClassName` | `standard` | 存储类 |
| 数据卷大小 | `5Gi` | 每个 Redis 实例 |
| nodeConf 卷大小 | `1Gi` | 存放 nodes.conf |
| `nodeConfVolume` | `true` | 集群模式必须开启 |
| 默认密码 | `123456` | 存于 `redis-secret` |
| ACL 用户 | `default`, `opstree`, `buildpiper` | 存于 `redis-acl-secret` |
| 反亲和性策略 | `requiredDuringScheduling...` | **硬性**：禁止同节点 |
| `runAsNonRoot` | `true` | 以非 root 运行 |
| `runAsUser` | `1000` | UID 1000 |
| `allowPrivilegeEscalation` | `false` | 禁止特权提升 |
| `seccompProfile` | `RuntimeDefault` | 默认安全计算模式 |

---

## 11. 生产运维操作

### 11.1 一键部署所有资源

```bash
kubectl apply -f manifests/01-namespace.yaml
kubectl apply -f manifests/02-acl-secret.yaml
kubectl apply -f manifests/03-redis-password-secret.yaml
kubectl apply -f manifests/04-redis-cluster.yaml
kubectl apply -f manifests/05-servicemonitor.yaml
```

### 11.2 水平扩容

修改 `04-redis-cluster.yaml` 中的 `clusterSize`：

```yaml
spec:
  clusterSize: 6   # 从 3 扩容至 6 主节点
```

```bash
kubectl apply -f manifests/04-redis-cluster.yaml
```

> [!WARNING]
> 扩容前确认有足够可用 Node（硬性反亲和性每个 Pod 独占一个 Node）。

### 11.3 更新 ACL 配置

```bash
kubectl apply -f manifests/02-acl-secret.yaml
kubectl rollout restart statefulset redis-cluster-leader -n redis
kubectl rollout restart statefulset redis-cluster-follower -n redis
```

### 11.4 查看 Operator 日志

```bash
kubectl logs -n redis-operator \
  $(kubectl get pod -n redis-operator -l name=redis-operator \
    -o jsonpath='{.items[0].metadata.name}') -f
```

### 11.5 删除集群（谨慎）

```bash
kubectl delete -f manifests/04-redis-cluster.yaml
# PVC 不会自动删除，数据仍在
kubectl get pvc -n redis
# 确认无需后手动删除
kubectl delete pvc -n redis --all
```

> [!CAUTION]
> 删除 PVC 将**永久丢失**所有 Redis 数据，操作前请确保已完成备份。

---

## 12. 常见问题排查

### Q1: Pod 一直处于 Pending

**原因**：硬性反亲和性无法满足（可用 Node 数 < 6）。

```bash
kubectl describe pod <pod-name> -n redis | grep -A 20 Events
```

**解决**：增加 Worker Node，或改为软性策略（`preferredDuringScheduling...`）。

### Q2: PVC 无法绑定

```bash
kubectl describe pvc <pvc-name> -n redis
kubectl get storageclass standard
```

确认 `standard` StorageClass 存在且支持动态制备。

### Q3: Cluster 未形成（cluster_state: fail）

```bash
kubectl logs -n redis-operator <operator-pod> -f
kubectl describe rediscluster redis-cluster -n redis
```

### Q4: ACL 验证失败（WRONGPASS）

```bash
kubectl get secret redis-acl-secret -n redis \
  -o jsonpath='{.data.acl\.conf}' | base64 -d
```

### Q5: 监控指标抓取失败

```bash
kubectl get svc -n redis --show-labels | grep redis-cluster
kubectl port-forward pod/redis-cluster-leader-0 9121:9121 -n redis
curl -s http://localhost:9121/metrics | head -20
```

---

## 附录：资源消耗估算（6 节点集群）

| 资源 | Redis 容器 x6 | Exporter 容器 x6 | 合计 |
|------|--------------|-----------------|------|
| CPU Request | 600m | 600m | **1200m（1.2 core）** |
| CPU Limit | 600m | 600m | **1200m（1.2 core）** |
| Memory Request | 768Mi | 768Mi | **1536Mi（1.5 Gi）** |
| Memory Limit | 768Mi | 768Mi | **1536Mi（1.5 Gi）** |
| 数据 PVC | 30Gi | - | **30Gi** |
| nodeConf PVC | 6Gi | - | **6Gi** |
| **存储合计** | | | **36Gi** |

> [!TIP]
> 生产环境建议适当提高内存 limit，并通过 `additionalRedisConfig` 配置 `maxmemory` 和 `maxmemory-policy`。

---

*文档生成时间：2026-05-01 | 参考：https://github.com/OT-CONTAINER-KIT/redis-operator*
