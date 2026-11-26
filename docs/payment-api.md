# 支付模块 API

支付模块位于 `ledgerflow-app` 的 `com.ledgerflow.payment` 包，随单体应用运行（默认 `8080`）。
支付回调与订单、库存、Outbox 共用同一个 MySQL 库和本地事务。

设计依据：[`payment-and-mq-design.md`](payment-and-mq-design.md)。
模块边界与职责速览：[`payment-module.md`](payment-module.md)。

> 支付模块直接读写订单/库存表，以保证回调事务的原子性；它不是独立微服务。
> 拆分条件见 [`module-design.md`](module-design.md)。

## 在整体中的位置

```text
ledgerflow (pom)
├─ ledgerflow-common   纯 jar：雪花 ID、单号、状态枚举
└─ ledgerflow-app      单体应用：catalog / inventory / order / checkout / payment / outbox
```

- `payment` 包通过 MyBatis Mapper 读写 `orders`、`inventory` 等表，
  所有操作在同一个本地事务里完成。
- 全应用只有一个 Spring Boot 入口和一份 Flyway 迁移（`db/migration` V1–V8）。

## 快速开始

```bash
# 1. MySQL
cd /path/to/ledgerflow && docker compose up -d

# 2. 首次初始化演示数据（仅空库）
docker exec -i ledgerflow-mysql mysql -uroot -p123123 ledgerflow < db/demo/seed.sql

# 3. 打包并启动应用（dev profile 才能使用 Mock 收银台）
mvn -DskipTests package
java -jar ledgerflow-app/target/ledgerflow-app-0.0.1-SNAPSHOT.jar --spring.profiles.active=dev
```

启动时会自动执行 Flyway V1–V8。

## API

| 方法 | 路径 | 用途 |
|---|---|---|
| `POST` | `/api/orders/{orderNo}/payments` | 创建/复用支付尝试，返回 `paymentNo` 与 `payUrl` |
| `GET` | `/api/payments/{paymentNo}` | 前端轮询支付状态 |
| `POST` | `/api/payments/callback/{channel}` | 渠道异步回调（验签 + 幂等 + 状态推进） |
| `POST` | `/api/mock-channel/pay/{paymentNo}` | **仅 dev**：模拟渠道异步通知 |

创建支付：

```bash
curl -X POST http://localhost:8080/api/orders/LF373271725637632000/payments \
  -H 'Content-Type: application/json' \
  -H 'X-User-Id: 1' \
  -d '{"channel":"MOCK","clientToken":"pay-7f3c2a1b"}'
```

模拟支付成功 / 失败：

```bash
curl -X POST http://localhost:8080/api/mock-channel/pay/PAY373271725637632001 \
  -H 'Content-Type: application/json' -d '{"success":true}'

curl -X POST http://localhost:8080/api/mock-channel/pay/PAY373271725637632001 \
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
OUTBOX_PUBLISHER_ENABLED=true java -jar ledgerflow-app/target/ledgerflow-app-0.0.1-SNAPSHOT.jar \
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
