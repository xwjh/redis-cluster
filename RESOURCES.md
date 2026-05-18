# Redis Cluster 资源清单

## 本地文件

- `deploy.sh`：一键部署脚本。
- `cleanup.sh`：一键清理脚本。
- `manifests/01-namespace.yaml`：命名空间声明 (redis-operator + redis)。
- `manifests/02-acl-secret.yaml`：ACL 规则 Secret（用户权限文件）。
- `manifests/03-redis-password-secret.yaml`：default 用户密码 Secret。
- `manifests/04-redis-cluster.yaml`：RedisCluster CR（核心，3 主 3 从 + PVC + 反亲和性）。
- `manifests/05-servicemonitor.yaml`：Prometheus ServiceMonitor（可选）。
- `PLAN.md`：方案说明与架构图。
- `OPERATIONS.md`：操作手册（部署、验证、运维、排障）。
- `RESOURCES.md`：本文件，资源清单与官方资料。

## Kubernetes 资源清单

| 类型 | 名称 | Namespace | 说明 |
|---|---|---|---|
| Namespace | `redis-operator` | - | Operator 命名空间 |
| Namespace | `redis` | - | Cluster 命名空间 |
| Helm Release | `redis-operator` | `redis-operator` | OT-CONTAINER-KIT Operator |
| Deployment | `redis-operator` | `redis-operator` | Operator 控制器 |
| CRD | `redisclusters.redis.redis.opstreelabs.in` | - | RedisCluster 资源定义 |
| CRD | `redisreplications.redis.redis.opstreelabs.in` | - | RedisReplication |
| CRD | `redissentinels.redis.redis.opstreelabs.in` | - | RedisSentinel |
| CRD | `redis.redis.redis.opstreelabs.in` | - | Redis 单实例 |
| RedisCluster | `redis-cluster` | `redis` | 3 主 3 从集群 |
| StatefulSet | `redis-cluster-leader` | `redis` | 3 个主节点（由 Operator 生成） |
| StatefulSet | `redis-cluster-follower` | `redis` | 3 个从节点（由 Operator 生成） |
| Pod | `redis-cluster-leader-{0,1,2}` | `redis` | 主节点（2容器：redis + exporter） |
| Pod | `redis-cluster-follower-{0,1,2}` | `redis` | 从节点（2容器：redis + exporter） |
| Secret | `redis-acl-secret` | `redis` | ACL 规则文件（用户提供） |
| Secret | `redis-secret` | `redis` | default 密码（用户提供） |
| PVC | `data-volume-redis-cluster-leader-{0,1,2}` | `redis` | 主节点数据 5Gi x3 |
| PVC | `data-volume-redis-cluster-follower-{0,1,2}` | `redis` | 从节点数据 5Gi x3 |
| PVC | `node-conf-redis-cluster-leader-{0,1,2}` | `redis` | 主节点 nodes.conf 1Gi x3 |
| PVC | `node-conf-redis-cluster-follower-{0,1,2}` | `redis` | 从节点 nodes.conf 1Gi x3 |
| ServiceMonitor | `redis-cluster-monitor` | `redis` | Prometheus 抓取配置（可选） |
| Image (redis) | `quay.io/opstree/redis:latest` | - | Redis 主镜像 |
| Image (exporter) | `quay.io/opstree/redis-exporter:latest` | - | 监控 sidecar 镜像 |

## 资源消耗估算 (6 节点)

| 资源 | Redis 容器 x6 | Exporter 容器 x6 | 合计 |
|---|---|---|---|
| CPU Request | 600m | 600m | **1200m** |
| CPU Limit | 600m | 600m | **1200m** |
| Memory Request | 768Mi | 768Mi | **1.5Gi** |
| Memory Limit | 768Mi | 768Mi | **1.5Gi** |
| 数据 PVC | 30Gi | - | **30Gi** |
| nodeConf PVC | 6Gi | - | **6Gi** |
| **存储合计** | | | **36Gi** |

## 官方资料

- OT-CONTAINER-KIT redis-operator GitHub：https://github.com/OT-CONTAINER-KIT/redis-operator
- redis-operator 文档：https://ot-container-kit.github.io/redis-operator/
- Helm Chart 仓库：https://ot-container-kit.github.io/helm-charts/
- RedisCluster v1beta2 API 参考：https://ot-container-kit.github.io/redis-operator/api/redis-cluster/
- ACL 配置示例：https://github.com/OT-CONTAINER-KIT/redis-operator/tree/main/example/v1beta2
