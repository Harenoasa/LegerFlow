# payment-service

支付子模块：支付单、渠道回调、退款与 Outbox。独立进程运行（默认 `8081`），
与 `common` 共用同一个 MySQL 库，保证支付回调能在**一个本地事务**里
完成支付单、订单、库存、状态日志和 Outbox 的写入。

设计依据：[`docs/payment-and-mq-design.md`](../docs/payment-and-mq-design.md)。
模块边界与职责速览：[`docs/payment-module.md`](../docs/payment-module.md)。

> 这是 **过渡结构**，不是严格微服务：支付服务直接读写下单应用的订单/库存表，
> 并依赖 `common` 的实体与 Mapper。它适合先把回调事务、幂等和 Outbox
> 跑通；真正的服务拆分条件见 [`docs/module-design.md`](../docs/module-design.md)。

## 在整体中的位置

```text
ledgerflow (pom)
├─ ledgerflow-common   订单/商品/库存应用（8080）+ 共享实体/Mapper/Flyway/雪花 ID
└─ payment-service     本模块：创建支付、回调、退款、Outbox（8081）
```

- `payment-service` 依赖 `common`，复用其中的 `OrdersEntity`、库存实体、
  MyBatis Mapper 与 `V1–V8` Flyway 迁移脚本。
- 为此 `common` 的 `spring-boot-maven-plugin` 配置了
  `<classifier>exec</classifier>`：普通 jar 作为依赖，可执行包名为
  `ledgerflow-common-0.0.1-SNAPSHOT-exec.jar`。
- 两个应用共用一张 Flyway history 表，启动顺序不限，Flyway 会加锁串行执行迁移。

## 快速开始

```bash
# 1. MySQL
cd /path/to/ledgerflow && docker compose up -d

# 2. 首次初始化演示数据（仅空库）
docker exec -i ledgerflow-mysql mysql -uroot -p123123 ledgerflow < db/demo/seed.sql

# 3. 打包并启动支付服务（dev profile 才能使用 Mock 收银台）
#    在仓库根目录执行；先打包是为了让 payment-service 能拿到 ledgerflow-common 的普通 jar
mvn -DskipTests package
java -jar payment-service/target/payment-service-0.0.1-SNAPSHOT.jar --spring.profiles.active=dev
```

启动时会自动执行 `V8__payment_idempotency_and_settlement.sql`。

## API

| 方法 | 路径 | 用途 |
|---|---|---|
| `POST` | `/api/orders/{orderNo}/payments` | 创建/复用支付尝试，返回 `paymentNo` 与 `payUrl` |
| `GET` | `/api/payments/{paymentNo}` | 前端轮询支付状态 |
| `POST` | `/api/payments/callback/{channel}` | 渠道异步回调（验签 + 幂等 + 状态推进） |
| `POST` | `/api/mock-channel/pay/{paymentNo}` | **仅 dev**：模拟渠道异步通知 |

创建支付：

```bash
curl -X POST http://localhost:8081/api/orders/LF373271725637632000/payments \
  -H 'Content-Type: application/json' \
  -H 'X-User-Id: 1' \
  -d '{"channel":"MOCK","clientToken":"pay-7f3c2a1b"}'
```

模拟支付成功 / 失败：

```bash
curl -X POST http://localhost:8081/api/mock-channel/pay/PAY373271725637632001 \
  -H 'Content-Type: application/json' -d '{"success":true}'

curl -X POST http://localhost:8081/api/mock-channel/pay/PAY373271725637632001 \
  -H 'Content-Type: application/json' -d '{"success":false}'
```

Mock 回调会走和真实渠道相同的路径：`MockPayChannel` 生成 HMAC-SHA256 签名，
`PaymentCallbackService` 验签、写 `payment_callback_log` 幂等闸门，再推进状态。

## 支付成功事务

`PaymentCallbackService.handle` 在同一个事务里按固定顺序完成：

1. `INSERT IGNORE payment_callback_log`：`(channel, notify_id)` 唯一键挡重复通知
2. 锁 `orders` → `payment_order`（与关单任务保持相同加锁顺序）
3. 校验渠道、金额（`BigDecimal.compareTo`）
4. `payment_order` 条件更新为成功
5. `orders` 条件更新为已支付，并写 `paid_payment_no`
6. 库存 `locked_stock → sold_stock`；先插 `inventory_log` 做业务幂等
7. `order_status_log` + `outbox_event`

订单已取消 / 已被另一笔支付结算时，`orders` 条件更新影响 0 行：
钱已经到账，不能把订单改回已支付，改为**记支付成功 + 创建退款单 + 写
`PAYMENT_LATE_OR_DUPLICATE` 事件**。

## V8 迁移做了什么

- `payment_order.client_token` + `uk_order_client_token`：支付创建幂等
- `orders.paid_payment_no` + `uk_paid_payment_no`：一个订单只结算一笔支付
- `payment_order.idx_order_status`：按订单查待支付单
- `processed_event`：后续 Kafka 消费端通用去重表

## Outbox 与 Kafka

业务事务只写 `outbox_event`，不在事务里发 Kafka。投递器默认关闭：

```bash
OUTBOX_PUBLISHER_ENABLED=true java -jar payment-service/target/payment-service-0.0.1-SNAPSHOT.jar \
  --spring.profiles.active=dev
```

打开后 `OutboxPublisher` 每秒扫描 `status IN (0,2)` 的事件，发送到：

- `ledgerflow.payment.events.v1`（`aggregate_type=PAYMENT`）
- `ledgerflow.refund.events.v1`（`aggregate_type=REFUND`）

Kafka key 使用 payload 里的 `orderNo`，保证同一订单的事件进同一分区。
失败按 `1s → 2s → 4s … 最多 300s` 退避重试。本地 Kafka 与 topic 创建方式见
设计文档 3.9 节；当前没有实现死信队列与监控指标。

## 尚未实现（下一步）

- 订单超时关单任务（`orders` 扫描 + 释放库存）与支付单批量关闭
- 真实支付宝/微信渠道适配器、退款渠道调用
- Kafka 消费者、`processed_event` 去重、DLT
- 并发回调 / 关单竞态 / 重复支付的集成测试（Testcontainers）
- 前端支付页与轮询
