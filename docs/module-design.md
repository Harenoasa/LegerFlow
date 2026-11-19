# LedgerFlow 模块设计说明

> 本文回答三个问题：现在有哪些模块、每个模块做什么、哪些设计需要调整。
> 依据根目录 [`README.md`](../README.md) 的项目计划，以及当前 `pom.xml` 和源码。
> 支付链路的详细设计见 [`payment-and-mq-design.md`](payment-and-mq-design.md)，
> 支付模块的职责速览见 [`payment-module.md`](payment-module.md)。

## 0. 一句话结论

当前项目**不是微服务系统**，而是：

> 一个订单/商品单体应用（`common`）  
> \+ 一个独立启动的支付进程（`payment-service`）  
> \+ 共享 MySQL 库和共享域模型。

根 README 里的 `order / payment / inventory / ledger / outbox / search / common`
是**逻辑模块**，不是 7 个 Maven 模块。目前真正参与构建的物理模块只有两个。

## 1. 先分清“逻辑模块”和“物理模块”

| 概念 | 含义 | 例子 |
|---|---|---|
| 逻辑模块 | 按业务职责划分的代码区域，可以是一个 package，也可以是一个 jar 或进程 | `order`、`payment`、`inventory` |
| 物理模块 | Maven `<module>`，有自己的 `pom.xml`，能单独编译、打包、运行 | `common`、`payment-service` |

把“逻辑模块”直接理解成“微服务”，是当前设计最容易误解的地方。

## 2. 当前物理结构

| 模块 / 目录 | 类型 | 默认端口 | 现在负责什么 | 状态 |
|---|---|---|---|---|
| `pom.xml`（根） | Maven reactor | — | 聚合模块、统一 Spring Boot / Java / MyBatis-Plus 版本 | 可用 |
| `common` | Spring Boot 应用 + 共享域 | `8080` | 订单/商品/库存接口、下单锁库存、Flyway V1–V8、共享实体/Mapper、雪花 ID、订单状态枚举 | 名字叫 common，实际是“订单应用 + 共享库” |
| `payment-service` | Spring Boot 应用 | `8081` | 支付单、渠道预下单、回调验签/幂等、退款单、Outbox 投递 | Mock 渠道全链路可用 |
| `frontend` | Vue 3 + Vite + TS | `5173` | 商品浏览、购物车、结算；`/api` 目前只代理到 `8080` | 没有支付页 |
| `db` | SQL 文档与脚本 | — | 数据库设计、seed/reset、对账/并发/索引查询 | Flyway 迁移实际在 `common` 的 resources 里 |
| `docs` | 设计文档 | — | 数据库、DTO、支付/MQ、注入风格等说明 | — |
| `compose.yml` | 本地基础设施 | — | MySQL 8.4 | Kafka、Elasticsearch 尚未加入 |
| `order-service` / `accounting-service` | 未来模块 | — | 根 POM 中仍是注释 | 不存在，不要按已实现来理解 |

## 3. 根 README 里的 7 个逻辑模块

| 逻辑模块 | 应该做什么 | 代码现在在哪 | 完成度 / 说明 |
|---|---|---|---|
| `order` | 创建订单、查询、取消、超时关单、状态流转审计 | `common` 的 controller/service | 下单已实现；订单查询、取消、超时关单未实现 |
| `payment` | 创建/复用支付尝试、渠道预下单、回调、退款、支付状态查询 | `payment-service` | Mock 渠道和回调事务已实现；真实渠道、退款执行、关单任务未实现 |
| `inventory` | 下单锁库存、支付后 `locked → sold`、取消/关单释放库存 | 下单在 `CreateService`，支付扣减在 `PaymentCallbackService` | 锁定和支付扣减已实现；取消/超时释放未实现；没有独立模块 |
| `ledger` | 复式记账、分录、对账、结算 | 未实现 | 计划放到未来的 `accounting-service`；当前只有支付事件可供消费 |
| `outbox` | 业务事务内写事件，投递器可靠发到 Kafka | `payment-service/outbox` | 已实现；投递器默认关闭；消费端未实现 |
| `search` | 订单/流水写入 Elasticsearch，提供检索和聚合 | 未实现 | README 第三周计划 |
| `common` | 共享实体、Mapper、ID 生成、订单状态等 | `common` 的 `common/entity/mapper` 包 | 已存在，但和订单应用混在同一个 Maven 模块里 |

## 4. 依赖与数据流

```text
frontend :5173
   │  /api（Vite proxy，目前只指向 8080）
   ▼
ledgerflow-common :8080
   ├─ 订单 / 商品 / 库存接口
   ├─ 共享实体、Mapper、Flyway V1–V8、雪花 ID、OrderStatus
   └──────────────────────────┐
                              ▼
                     MySQL ledgerflow
                              ▲
payment-service :8081 ────────┘
   ├─ 支付 / 退款 / 回调
   └─ OutboxPublisher ──(可选)──► Kafka ledgerflow.payment.events.v1
```

关键点：

- 两个应用之间 **没有 HTTP 调用**；`payment-service` 直接读写订单/库存表，并复用
  `common` 的实体和 Mapper。
- 所以支付回调才能在一个本地事务里完成“支付单 + 订单 + 库存 + 状态日志 + Outbox”。
- 这也是它**不能被称为严格微服务**的原因：数据库和领域模型仍然是共享的。

## 5. 现有设计的合理点与问题

### 5.1 合理的部分

- **同步核心 + 异步外围**：支付回调同步落库；记账、通知、搜索、分析走 Outbox + Kafka。
- **共享数据库本地事务**：在尚未真正拆服务时，这是保证支付/订单/库存不跨库不一致的最简单办法。
- **多层幂等**：回调日志唯一键、条件更新、`paid_payment_no` 唯一约束、库存流水唯一键。
- **支付单独进程**：适合练习独立部署、端口隔离和后续拆分；但当前仍是过渡结构。
- **Outbox 默认关闭**：本地没起 Kafka 时也能跑通支付主链路。

### 5.2 需要调整的地方

| 问题 | 影响 | 本次处理 | 建议 |
|---|---|---|---|
| `common` 名称与职责不符 | 新人以为它是工具库；`payment-service` 依赖了整个订单应用；需要 `classifier=exec` 规避可执行 jar | 在 POM 和文档中明确“订单应用 + 共享域”双重角色 | 拆成 `common`（共享库）+ `order-service`（应用），见 6.1 |
| `payment-service` 是“分布式单体” | 共享表、共享迁移、共享实体，无法独立演进数据库 | 文档中明确它是过渡结构 | 先接受；等真正需要独立部署/团队/扩容时再拆数据库，见 6.3 |
| 包名不统一 | `com.harenoasa.ledgerflowcommon`、`com.harenoasa.ledgerflow.payment` 与 groupId `com.ledgerflow` 三套命名 | 暂未重命名（改动面大） | 统一为 `com.ledgerflow.common` / `.order` / `.payment` |
| 根 POM 有未使用的 MyBatis Spring Boot 依赖管理；common 有未使用的 Kafka 依赖 | 依赖噪音，容易误以为项目用 MyBatis 原生 starter | 已删除；MyBatis-Plus 版本提升到根 POM 管理 | 保持“用什么声明什么” |
| 订单状态常量重复 | `common` 里的 `OrderStatus` 是普通类，支付模块另建 `OrderStatusCodes` | 已改成共享枚举并删除重复常量 | 后续状态码只从 `OrderStatus` 取 |
| 前端只代理 8080 | 支付接口在 8081，支付页接不进来 | 文档记录 | 加支付页时用网关或增加精确的 Vite proxy 规则 |
| Kafka / ES 不在 compose 中 | Outbox 投递器和消费端无法本地联调 | 未改 | 下一步补 Kafka + Kafka UI，再补消费者 |
| 根目录不是 git 仓库，只有 `common` 是 | `payment-service`、`db`、`docs` 没有被版本管理 | 未改（需要你决定） | 在根目录 `git init`，把子仓库历史迁进来或统一为一个仓库 |
| 文档里的迁移版本/表数量过期 | 仍写 V1–V7、22 张表 | 已更新为 V1–V8、23 张表，并让 reset/seed 覆盖 `processed_event` | 后续迁移变更时同步更新 |

## 6. 推荐的目标结构

### 6.1 最小、最值得做的拆分（推荐）

```text
ledgerflow (pom)
├─ ledgerflow-common   (jar)  共享域：实体、Mapper、Flyway V1–V8、雪花 ID、OrderStatus
├─ order-service       (app)  订单/商品/库存接口，默认 8080
└─ payment-service     (app)  支付/退款/回调/Outbox，默认 8081，只依赖 common
```

拆分步骤：

1. 新建 `order-service` Maven 模块，把 `LedgerflowCommonApplication`、两个 Controller、
   `CreateService`、`ProductQueryService`、订单/商品 DTO、`OrderNoGenerator` 和
   `application.yaml` 移过去。
2. `common` 只保留支付也需要的共享部分：
   `OrdersEntity`、`OrderItemEntity`、`OrderStatusLogEntity`、对应 Mapper、
   `SnowflakeIdGenerator`、`OrderStatus` 枚举、`db/migration`。
3. 商品、SKU、地址这些只有订单应用使用的实体/Mapper 移到 `order-service`。
4. `common` 去掉 `@SpringBootApplication` 和 Spring Boot 可执行插件，
   变成普通 jar；`payment-service` 不再需要 `classifier=exec` 的绕行配置。
5. `order-service` 和 `payment-service` 分别配置 `@MapperScan`，都从 classpath 执行同一份
   Flyway 迁移。

收益：`common` 名实相符；支付不再依赖订单应用的 Controller/Service；模块边界一眼能看懂。
注意：这仍然共享数据库，只是**代码边界**变清晰，不是微服务拆分。

### 6.2 包名统一（可选，建议独立一次提交）

```text
com.ledgerflow.common   共享实体、Mapper、ID、状态
com.ledgerflow.order    订单/商品应用
com.ledgerflow.payment  支付应用
```

groupId 已经是 `com.ledgerflow`，包名跟上后，依赖坐标和 import 就一致了。
这是机械改动，建议用 IDE 的 Rename Package 一次做完，不要和业务修改混在一起。

### 6.3 真正拆成微服务（以后再做）

只有出现下面这些信号才值得拆：

- 支付需要独立扩容/独立发布/独立团队；
- 订单和支付需要各自的数据库与发布节奏；
- 能接受“回调本地事务 + Outbox/Saga + 对账补偿”代替跨表事务。

那时 `payment-service` 应拥有自己的支付库，订单状态通过 API 或事件推进，
库存由订单/库存服务负责；代价是失去当前“一个本地事务搞定一切”的简单性。
现在不建议继续拆。

## 7. 本次实际修改

- `OrderStatus` 从普通类改为枚举，code 与 `V4__orders.sql` 对齐；
  `CreateService` 和支付模块统一使用它。
- 删除 `payment-service` 中重复的 `OrderStatusCodes`。
- 根 `pom.xml`：集中管理 MyBatis-Plus 版本，删除未使用的 MyBatis Spring Boot 依赖管理。
- `../common`：删除未使用的 Kafka 依赖，补充模块双重角色说明。
- `payment-service/pom.xml`：显式声明 MyBatis-Plus、Flyway、MySQL 驱动，不再依赖传递依赖。
- 根 README、`payment-service/README.md`、`db/README.md`、`docs/database-design.md`
  同步模块说明、V1–V8 和 23 张表。
- `db/demo/reset.sql`、`db/demo/seed.sql` 增加 `processed_event` 清理。

本次**没有**做 `common` / `order-service` 的大拆分，也没有重命名包；
这两项改动面大，适合按 6.1、6.2 单独做。所有修改不改变业务行为，
`mvn -DskipTests package` 与支付/雪花单元测试均通过。

## 8. 留给你的练习

1. 按 6.1 把 `common` 拆成共享库 + `order-service`，跑通两个进程。
2. 按 6.2 统一包名，观察 `@MapperScan` 和 Spring 组件扫描的变化。
3. 给前端加支付页，并决定用 Vite proxy 还是 Spring Cloud Gateway 统一 8080/8081。
4. 补 Kafka 消费者：用 `processed_event` 去重，处理失败重试和 DLT。

## 9. 相关文档

- [`README.md`](../README.md)：项目目标、快速开始、四周计划
- [`payment-module.md`](payment-module.md)：支付模块职责速览
- [`payment-and-mq-design.md`](payment-and-mq-design.md)：支付回调、幂等、Kafka/Outbox 详细设计
- [`database-design.md`](database-design.md)：数据库与表设计
- [`payment-service/README.md`](../payment-service/README.md)：支付服务运行方式和 API
- [`dependency-injection-style.md`](dependency-injection-style.md)：本项目的依赖注入约定
