# LedgerFlow 模块设计说明

> 本文说明重构后的物理模块、业务包边界和后续拆分方向。
> 支付链路的详细设计见 [`payment-and-mq-design.md`](payment-and-mq-design.md)，
> 支付模块的职责速览见 [`payment-module.md`](payment-module.md)，
> 运行方式和 API 见 [`payment-api.md`](payment-api.md)。

## 0. 一句话结论

当前项目是**单进程的模块化单体**：

> 一个 Spring Boot 应用（`ledgerflow-app`，默认 8080）+ 一个共享技术内核 jar（`ledgerflow-common`）+ 一个 MySQL 库和一份 Flyway 迁移。

业务边界通过 `com.ledgerflow` 下的业务包划分，不再拆成多个共享数据库的 Maven 应用。

## 1. 逻辑模块和物理模块

| 概念 | 含义 | 例子 |
|---|---|---|
| 业务模块 | 按业务职责划分的包，拥有自己的表、实体、Mapper 和服务 | `catalog`、`inventory`、`order`、`payment` |
| 物理模块 | Maven `<module>`，有自己的 `pom.xml` | `ledgerflow-common`、`ledgerflow-app` |

业务模块现在是**包**，不是独立进程。把业务包直接理解成微服务，是这套结构最容易误解的地方。

## 2. 当前物理结构

| 模块 / 目录 | 类型 | 端口 | 职责 |
|---|---|---|---|
| `ledgerflow-common` | 普通 jar（无 `@SpringBootApplication`） | — | 雪花 ID、订单/支付单号生成器、`OrderStatus` / `PaymentStatus` 枚举 |
| `ledgerflow-app` | Spring Boot 应用 | `8080` | 商品、库存、订单、支付、Outbox，唯一部署物 |
| `frontend` | Vue 3 + Vite + TS | `5173` | 商品浏览、购物车、结算；`/api` 代理到 8080 |
| `db` | SQL 文档与脚本 | — | seed/reset、对账/并发/索引查询 |
| `docs` | 设计文档 | — | 数据库、DTO、支付/MQ、模块说明 |
| `compose.yml` | 本地基础设施 | — | MySQL 8.4 |
| `ledger` / `search` | 空目录 | — | 记账消费者与商品搜索尚未实现 |
| `ledger-worker` | 未创建 | — | Kafka 记账阶段再拆出的独立进程 |

Flyway 迁移只由 `ledgerflow-app` 执行，位置是
`ledgerflow-app/src/main/resources/db/migration`，版本 V1–V8。

## 3. 业务包与表归属

| 业务包 | 拥有的表 | 当前实现 | 完成度 |
|---|---|---|---|
| `catalog` | `category`、`product_spu`、`product_sku`、`product_image` | 商品列表查询、SKU 价格与库存聚合 | 商品查询已实现 |
| `inventory` | `inventory`、`inventory_log` | 下单锁库存、支付成功 `locked → sold`、库存流水 | 锁定与核销已实现；释放未实现 |
| `order` | `orders`、`order_item`、`order_status_log`、`user_address` | 下单、订单/明细/状态日志写入 | 下单已实现；查单、取消、超时关单未实现 |
| `checkout` | 无表 | 下单编排（地址、商品、库存、订单） | 下单编排已实现 |
| `payment` | `payment_order`、`payment_callback_log`、`refund_order` | 创建/复用支付单、渠道回调、退款单、支付查询 | Mock 渠道全链路已实现；真实渠道、退款执行未实现 |
| `outbox` | `outbox_event`、`processed_event` | 事务内追加事件、Kafka 投递器 | 投递器已实现且默认关闭；消费端未实现 |
| `common` | 无表 | 雪花 ID、单号、状态枚举 | 已实现 |
| `ledger` | 未建表 | Kafka 消费、复式记账、对账 | 留空 |
| `search` | 无 MySQL 表 | 商品搜索读模型 | 留空 |

说明：

- `user_address` 暂时由 `order` 包读取；接入用户/地址管理后再单独拆包。
- 购物车、优惠券、营销、售后、发货等表已在迁移中，但本次没有建立对应业务包。
- `processed_event` 是后续 Kafka 消费者共用的去重表，暂放在 `outbox` 包。

## 4. 依赖与数据流

```text
frontend :5173
   │  /api（Vite proxy）
   ▼
ledgerflow-app :8080
   ├─ catalog / inventory / order / checkout
   ├─ payment / outbox
   └──────────────────────────┐
                              ▼
                     MySQL ledgerflow
```

- 全应用只有一个进程、一个数据源、一份 Flyway history。
- 支付回调仍在同一个本地事务里完成支付单、订单、库存、状态日志和 Outbox 的写入，
  这是当前共享数据库换来的简单性。
- Kafka 只接 Outbox 的下游投递，同步链路不发消息。

## 5. 模块边界规则

目标规则：

1. **表只归一个业务包写**：每个业务包只操作自己拥有的表。
2. **跨包传 DTO/值对象**，不传 Entity；Mapper 留在所属业务包。
3. **`checkout` 只做编排**，不拥有表，负责下单等跨包事务的边界。
4. **`outbox` 只负责事件追加和投递**，业务包不直接发 Kafka。
5. **依赖方向保持无环**：`catalog` / `inventory` / `order` 依赖 `common`；
   `checkout` 编排它们；`payment` 使用订单/库存数据；`ledger` 只消费事件。

当前代码仍有一处过渡：`PaymentCallbackService` 直接注入 `order` 和 `inventory`
的 Mapper，完成订单结算和库存核销。这样做是为了保持原有的单事务行为；
后续可以把这些操作收敛成 `order` / `inventory` 包内的模块 API，但不改变 SQL 和事务顺序。

## 6. 什么时候再拆进程

只有同时出现下面这些信号，才值得把某个业务包拆成独立服务：

- 需要独立扩容或独立发布；
- 有独立团队维护；
- 能接受独立数据库与跨服务一致性方案。

Kafka 记账阶段可以先把 `ledger` 做成独立的 `ledger-worker` 进程，
作为“同进程 vs 独立进程”的对照实验；订单、库存、支付继续共享交易库和本地事务。

真正拆 `payment` 时，支付库需要独立，订单状态通过 API 或事件推进，
再用 Outbox、幂等消费、Saga/补偿替代当前的跨表本地事务。现在不建议这样做。

## 7. 本次重构做了什么

- `common` 目录改名为 `ledgerflow-app`，作为唯一 Spring Boot 应用。
- 新建 `ledgerflow-common` 普通 jar，只保留雪花 ID、单号和状态枚举。
- 删除独立启动的 `payment-service`，把支付代码并入 `ledgerflow-app` 的 `payment` 包。
- 包名统一为 `com.ledgerflow.*`，按业务包重新组织：
  `catalog`、`inventory`、`order`、`checkout`、`payment`、`outbox`。
- Flyway V1–V8 只保留在 `ledgerflow-app`，全应用只有一个迁移执行者。
- 默认端口统一为 8080；前端 Vite proxy 不再需要指向第二个进程。
- `ledger`、`search` 保持空目录；`ledger-worker` 尚未创建。
- 未改变现有业务逻辑和接口路径。

## 8. 相关文档

- [`README.md`](../README.md)：项目目标、快速开始、四周计划
- [`payment-module.md`](payment-module.md)：支付模块职责速览
- [`payment-and-mq-design.md`](payment-and-mq-design.md)：支付回调、幂等、Kafka/Outbox 详细设计
- [`payment-api.md`](payment-api.md)：支付模块运行方式和 curl 示例
- [`database-design.md`](database-design.md)：数据库与表设计
- [`dependency-injection-style.md`](dependency-injection-style.md)：依赖注入约定
