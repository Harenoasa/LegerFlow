# 支付模块要做什么

> 本文是支付模块的“职责说明书”，不展开全部代码细节。
> 详细设计见 [`payment-and-mq-design.md`](payment-and-mq-design.md)，
> 运行方式和 curl 示例见 [`payment-api.md`](payment-api.md)，
> 模块整体划分见 [`module-design.md`](module-design.md)。

## 0. 一句话

支付模块负责：**把一个待支付订单的应付金额，变成一笔渠道可确认的支付结果，
并在本地事务里可靠地推进支付单、订单、库存和领域事件。**

它不负责订单生命周期、记账和库存主数据；这些分别属于订单应用和未来的记账服务。

## 1. 职责边界

### 1.1 要做什么

- 为“待支付且未过期”的订单创建或复用一笔支付尝试（`payment_order`）。
- 调用支付渠道预下单，拿到收银台地址或支付参数。
- 接收渠道异步回调：验签、解析、校验渠道和金额。
- 保证回调幂等：同一 `notify_id` 重复通知不能重复推进状态、不能重复扣库存。
- 维护支付单状态机：待支付 → 成功 / 失败 / 关闭。
- 支付成功时，在同一个本地事务里：
  - 支付单推进为成功；
  - 订单推进为已支付，并写入 `paid_payment_no`；
  - 库存 `locked_stock → sold_stock`；
  - 写订单状态日志；
  - 写 Outbox 事件。
- 处理晚到支付/重复支付：订单已取消或已被另一笔支付结算时，钱已经到账，
  **不能改订单状态**，而是记支付成功、创建退款单、写 `PAYMENT_LATE_OR_DUPLICATE` 事件。
- 提供支付状态查询，供前端轮询。
- 把领域事件可靠地交给 Outbox，后续由投递器发到 Kafka。

### 1.2 不做什么

- 不创建订单、不取消订单、不做订单超时关单；这些属于订单应用。
- 不维护商品、SKU、库存主数据；库存扣减只是支付结算的一部分。
- 不生成会计凭证、不做复式记账和对账；这些属于未来的 `ledger` / `accounting-service`。
- 不做用户认证；当前用 `X-User-Id` 模拟登录态。
- 不做支付页面、通知、搜索索引和分析报表；这些是前端或 Kafka 下游消费者的事。
- 当前也**不执行**真实渠道退款：只创建 `refund_order`，真正的退款调用尚未实现。
- 不在同步回调链路里发 Kafka；Kafka 只接 Outbox 的下游投递。

## 2. 三个核心状态

### 2.1 支付单 `payment_order.status`

| 值 | 含义 | 说明 |
|---|---|---|
| `0` | 待支付 | 创建支付单后的初始状态 |
| `1` | 成功 | 渠道确认收款；同一订单只能有一笔结算支付 |
| `2` | 失败 | 渠道明确失败，或预下单失败；订单仍可重新发起支付 |
| `3` | 关闭 | 同一订单换渠道/重复发起时，旧的待支付单被关闭 |

支付单允许从 `0/2/3` 推进到 `1`：渠道可能先失败、后成功，或关单后回调才到。
钱确实到账就必须记录，订单已不可支付时转为退款。

### 2.2 订单状态中与支付相关的部分

| 值 | 含义 | 支付模块的关系 |
|---|---|---|
| `0` | 待支付 | 只有这个状态可以创建支付、可以被回调结算 |
| `10` | 已支付 | 支付成功结算后的目标状态 |
| `40` | 已取消 | 晚到支付时不能改回 `10`，应创建退款 |
| `60` | 已退款 | 晚到/重复支付退款的后续状态 |

完整状态机见 [`database-design.md`](database-design.md) 和 `V4__orders.sql`；
代码里统一使用共享枚举 `OrderStatus`，不要另建常量。

### 2.3 退款单 `refund_order.status`

当前实现只创建退款单，初始 `status=0`。真实渠道退款、退款成功回调和退款重试尚未实现；
`refund_order` 的后续状态流转属于下一阶段。

## 3. 对外接口

| 方法 | 路径 | 用途 | 认证/签名 |
|---|---|---|---|
| `POST` | `/api/orders/{orderNo}/payments` | 创建/复用支付尝试，返回 `paymentNo`、`payUrl` | `X-User-Id` 模拟登录 |
| `GET` | `/api/payments/{paymentNo}` | 查询支付状态，供前端轮询 | 当前无鉴权 |
| `POST` | `/api/payments/callback/{channel}` | 渠道异步回调，验签 + 幂等 + 状态推进 | `X-Pay-Signature` |
| `POST` | `/api/mock-channel/pay/{paymentNo}` | 仅 `dev`：模拟渠道发送成功/失败回调 | 无（本地联调） |

创建支付请求体至少包含：

```json
{
  "channel": "MOCK",
  "clientToken": "pay-7f3c2a1b"
}
```

`clientToken` 是创建支付尝试的幂等键；金额由服务端从订单读取，客户端不能传金额。

## 4. 五条核心链路

### 4.1 创建支付

1. 锁 `orders` 行（`FOR UPDATE`），让同一订单的创建支付串行化。
2. 校验订单属于当前用户、状态为待支付、未过期、应付金额大于 0。
3. 按 `(order_no, client_token)` 查已有支付单，存在则直接复用。
4. 同渠道已有待支付单则复用；其他渠道有待支付单则先关闭（`status=3`）。
5. 插入新的 `payment_order`，金额只信订单的 `pay_amount`，过期时间不晚于订单。
6. 事务提交后调用渠道 `prepay`；预下单失败则把支付单置为失败，订单仍保持待支付。

### 4.2 支付成功回调（最核心）

`PaymentCallbackService.handle` 在**一个本地事务**里按固定顺序完成：

1. 渠道验签并解析回调；校验 `notifyId`、`paymentNo`、渠道、金额。
2. `INSERT IGNORE payment_callback_log`：`(channel, notify_id)` 唯一键挡住重复通知。
3. 锁 `orders` → `payment_order`，与关单任务保持相同加锁顺序。
4. 支付单条件更新为成功（`status <> 1`）；重复回调影响 0 行则直接返回成功。
5. 订单条件更新为已支付：`WHERE order_status=0 AND paid_payment_no IS NULL`，
   同时写 `pay_time`、`paid_payment_no`、`version+1`。
6. 订单更新影响 0 行说明订单已取消或已被另一笔支付结算 → 走 4.5 的退款分支。
7. 按 `skuId` 升序处理订单明细：先插 `inventory_log` 做业务幂等，再 `locked → sold`；
   库存更新 0 行必须抛异常回滚，避免账实不符。
8. 写 `order_status_log` 和 `PAYMENT_SUCCEEDED` Outbox 事件，标记回调已处理。

### 4.3 支付失败回调

渠道明确失败时，只把 `payment_order` 推进为失败（`status=2`），**订单仍保持待支付**，
用户可以重新发起支付。只有真正发生状态推进时才写 `PAYMENT_FAILED` 事件。

### 4.4 重复通知

同一个 `notify_id` 的第二次回调会在第 2 步被 `INSERT IGNORE` 挡住，直接返回成功；
不同 `notify_id` 但同一支付单的重复成功回调，会在支付单条件更新时影响 0 行，
同样安全返回。库存和 Outbox 都不会重复写。

### 4.5 晚到支付 / 重复支付

订单已经取消（`40`）或已被另一笔支付结算（`10`）时，钱仍然到账了：

1. 支付单照常记成功（钱不能丢）。
2. 订单状态保持不变，不写 `paid_payment_no`。
3. 在支付单行锁下计算已占用退款金额，创建 `refund_order`（`status=0`）。
4. 只有真正创建了退款单，才写 `PAYMENT_LATE_OR_DUPLICATE` 事件。
5. 库存不做任何扣减。

### 4.6 超时关单（尚未实现）

计划由订单应用的定时任务扫描 `order_status=0 AND expire_at<=NOW(3)`，
条件更新抢占订单并释放库存；支付模块批量关闭待支付单。
关单与回调必须保持 `orders → payment_order` 的加锁顺序，最终只能是：

- 订单已支付；或
- 订单已取消 + 支付单关闭；钱若晚到则创建退款。

## 5. 幂等与一致性

| 层次 | 机制 | 作用 |
|---|---|---|
| 创建支付 | `payment_order.uk_order_client_token(order_no, client_token)` | 同一请求重复提交只产生一笔支付单 |
| 回调入口 | `payment_callback_log.uk_channel_notify(channel, notify_id)` + `INSERT IGNORE` | 同一通知只处理一次 |
| 支付状态 | `UPDATE ... WHERE status <> 1` | 重复成功回调不会重复推进 |
| 订单结算 | `UPDATE ... WHERE order_status=0 AND paid_payment_no IS NULL` + `uk_paid_payment_no` | 一个订单只结算一笔支付 |
| 库存 | `inventory_log` 业务唯一键 + `locked → sold` 条件更新 | 同一支付单不会重复扣库存 |
| 退款 | 支付单行锁 + 已占用退款金额上限 | 重复通知不会重复退款 |
| 消费端 | `processed_event(consumer_group, event_id)` 唯一键 | Kafka 至少一次投递下的消费去重（待实现消费端） |

## 6. 数据与事件

### 6.1 支付模块自己拥有的表

- `payment_order`：支付尝试与状态。
- `payment_callback_log`：渠道回调原文与处理状态，幂等闸门。
- `refund_order`：退款单（当前只创建，不执行）。

`outbox_event` 由 `com.ledgerflow.outbox` 包统一追加和投递。

### 6.2 当前共享读写的表

支付包与订单/库存包在同一个应用、同一个数据库内，支付回调会直接读写：

- `orders`、`order_item`、`order_status_log`
- `inventory`、`inventory_log`

这是为了换取“一个本地事务完成结算”的简单性，属于**当前单体的过渡写法**。
后续可以把这些操作收敛到订单/库存包的模块 API；真正拆服务后，
这些表应归订单/库存服务所有，支付模块通过 API 或事件协作。

### 6.3 事件

| 事件 | 触发条件 | 当前 Topic |
|---|---|---|
| `PAYMENT_SUCCEEDED` | 订单成功结算 | `ledgerflow.payment.events.v1` |
| `PAYMENT_FAILED` | 支付单真正从待支付推进为失败 | `ledgerflow.payment.events.v1` |
| `PAYMENT_LATE_OR_DUPLICATE` | 晚到/重复支付且创建了退款单 | `ledgerflow.payment.events.v1` |

- 事件在业务事务内写入 `outbox_event`，不在事务里发 Kafka。
- `OutboxPublisher` 默认关闭，通过 `OUTBOX_PUBLISHER_ENABLED=true` 打开。
- Kafka key 使用 payload 里的 `orderNo`，保证同一订单的事件进同一分区。
- 投递失败按 `1s → 2s → 4s … 最多 300s` 退避重试。
- 消费端、`processed_event` 去重和 DLT 尚未实现；`refund` topic 预留给后续退款事件。

## 7. 当前完成度

**已实现**

- 创建/复用支付单，`clientToken` 幂等。
- Mock 渠道预下单、HMAC-SHA256 回调验签。
- 回调幂等、成功/失败状态推进、金额/渠道校验。
- 支付成功结算订单、扣减库存、写状态日志和 Outbox。
- 晚到/重复支付创建退款单和事件。
- 支付状态查询、dev 环境 Mock 收银台。
- 支付/雪花单元测试通过。

**未实现**

- 订单超时关单任务与支付单批量关闭。
- 真实支付宝/微信渠道适配器。
- 退款渠道调用、退款回调、退款重试。
- Kafka 消费者、`processed_event` 去重、DLT。
- 并发回调/关单竞态/重复支付的集成测试（Testcontainers）。
- 前端支付页与支付接口代理。
- 支付对账与监控指标。

## 8. 验收清单

| # | 场景 | 期望 |
|---|---|---|
| 1 | 待支付订单创建支付 | 201，`payment_order.status=0` |
| 2 | 已支付/已取消/已过期订单创建支付 | 409，不产生新支付单 |
| 3 | 成功回调 | 订单 `10`、支付单 `1`、库存 `locked→sold`、状态日志和 `PAYMENT_SUCCEEDED` 各一条 |
| 4 | 同一 `notify_id` 重复回调 | 返回成功，只有一条回调日志，库存不重复扣 |
| 5 | 金额与支付单不一致 | 409，支付单状态不变 |
| 6 | 渠道明确失败 | 支付单 `2`，订单仍为 `0`，写 `PAYMENT_FAILED` |
| 7 | 订单已取消后支付成功 | 支付单 `1`，订单仍 `40`，创建退款单，写 `PAYMENT_LATE_OR_DUPLICATE` |
| 8 | 同一订单两笔支付都成功 | 只有一笔结算订单，另一笔创建退款 |
| 9 | Outbox 投递失败 | 事件保留，按退避时间重试，不丢事件 |
| 10 | Kafka 重复投递 | 消费端按 `processed_event` 去重（待实现） |

## 9. 相关文档

- [`module-design.md`](module-design.md)：模块划分与拆分建议
- [`payment-and-mq-design.md`](payment-and-mq-design.md)：支付/回调/幂等/Kafka 详细设计
- [`payment-api.md`](payment-api.md)：运行方式、API、curl 示例
- [`database-design.md`](database-design.md)：表结构与状态机
- [`order-dto-design.md`](order-dto-design.md)：订单 DTO 与金额不变量
