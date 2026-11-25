# LedgerFlow

一个用于学习真实电商消费场景的 Spring Boot + MySQL 项目。数据库层包含
23 张业务表、Flyway V1–V8 迁移、可重复导入的样例数据、对账/并发/索引演示脚本和中文设计文档。
当前已实现订单/商品接口与独立的 `payment-service`；模块划分见
[`module-design.md`](module-design.md)，支付职责见 [`payment-module.md`](payment-module.md)。

## 技术栈

- Java 25 / Spring Boot 4.1.2（多模块，目前启用 `common` 与 `payment-service`）
- MySQL 8.4.11（Docker Compose，InnoDB，utf8mb4）
- Flyway 12.4（启动时自动迁移）
- MyBatis 4.0.1（已配置，尚未写 Mapper）

## 快速开始

```bash
# 1. 启动 MySQL（localhost:3306，库 ledgerflow）
docker compose up -d

# 2. 启动应用，让 Flyway 建表；看到迁移成功后 Ctrl+C
mvn -pl common spring-boot:run

# 3. 导入样例数据
docker exec -i -e MYSQL_PWD=123123 ledgerflow-mysql \
  mysql -uroot --default-character-set=utf8mb4 ledgerflow \
  < db/demo/seed.sql

# 4. 跑一个只读查询看看
docker exec -i -e MYSQL_PWD=123123 ledgerflow-mysql \
  mysql -uroot --default-character-set=utf8mb4 ledgerflow \
  < db/queries/01_basic.sql
```

完整的表设计、状态字典、设计取舍、演示脚本说明和练习题见
**[db/README.md](../db/README.md)**；订单创建接口的 Request/Response DTO 字段清单见
**[docs/order-dto-design.md](order-dto-design.md)**。

## 目录

```
compose.yml                 MySQL 8.4（root/123123，仅本地）
ledgerflow-common/          Spring Boot 模块（数据源 + Flyway）
db/
├── README.md               数据库设计主文档
├── demo/seed.sql           样例数据（8 条自检）
├── demo/reset.sql          清空业务数据
├── queries/01_basic.sql    分页、订单详情、商品、购物车、优惠券、搜索
├── queries/02_consistency.sql  对账巡检（正常零输出）
├── queries/03_concurrency.sql  并发/幂等演示（全部回滚）
├── queries/04_index_explain.sql  EXPLAIN 与深分页
└── optional/foreign_keys.sql   34 条物理外键（学习用）
docs/
└── order-dto-design.md     订单 Request/Response DTO 设计结论
```

## 已覆盖的真实问题

超卖、乐观锁、下单幂等、支付回调幂等、订单状态机、超时关单、部分退款、优惠券超发/重复使用、
软删除唯一约束、默认地址唯一、订单快照、无物理外键下的孤儿数据对账、深分页、
索引失效、中文全文搜索、Outbox 最终一致性。

## 安全提醒

- `root` / `123123` **仅用于本地开发**。配置支持 `DB_USERNAME` / `DB_PASSWORD`
  环境变量覆盖；生产必须使用最小权限账号和密钥管理，不要暴露 3306。
- `../db/demo/reset.sql` 会删除全部业务数据。
- `docker compose down -v` 会删除数据库卷，执行前务必确认。
- 样例账号密码为 `123456`，库中只有 BCrypt 哈希；真实系统禁止弱口令和明文存储。
