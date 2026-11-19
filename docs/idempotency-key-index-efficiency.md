# 幂等键索引效率：VARCHAR 与 BIGINT 对比

> 背景：前端 `CheckoutModal.makeClientToken()` 生成的幂等键形如 `web-<时间戳>-<随机串>`，
> 数据库存为 `orders.client_token VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin`，
> 并与 `user_id` 组成唯一索引 `uk_user_client_token(user_id, client_token)`（见 `V7__order_idempotency.sql`）。
> 本文讨论：带字符串前缀的 VARCHAR 键与 BIGINT 整型键在索引效率上的差异。

## 结论

有区别，但**前缀本身不是问题，真正影响索引效率的是 key 的总长度和随机性**。

## 当前 key 的实际大小

```ts
`web-${Date.now()}-${随机8位}`
```

- `web-` 4 字节
- 毫秒时间戳 13 位
- `-` 1 字节
- 随机串 8 位

合计约 **26 字节**（`ascii` 字符集下 1 字符 = 1 字节）。

索引是 `uk_user_client_token(user_id, client_token)`，InnoDB 二级索引的每条记录 = 索引列 + 主键：

| 方案 | 索引列 | 主键 `id` | 记录头/指针 | 单条约 |
|---|---|---|---|---|
| 当前 `VARCHAR(26)` | user_id 8 + 长度前缀 2 + token 26 | 8 | ~9 | **≈ 53 字节** |
| 改成 `BIGINT` | user_id 8 + token 8 | 8 | ~9 | **≈ 33 字节** |

## 三个维度上的实际差异

### 1. 索引体积 / 缓存命中（主要差异）

16KB 的页，按约 90% 填充算：

- `VARCHAR`：每页约 280 条
- `BIGINT`：每页约 460 条

同样 1000 万订单，这个二级索引大约 **530MB vs 350MB**。差 1.6 倍左右。

影响在于：索引更大 → Buffer Pool 中能缓存的行更少 → 唯一键检查、幂等查询更容易打到磁盘；INSERT 时页分裂、脏页刷盘也更多。但这是**量级上的渐进差异**，不是数量级差异。

### 2. 比较开销（差异小）

- `BIGINT`：一次 64 位整数比较。
- `ascii_bin` 的字符串：逐字节 `memcmp`。而且 token 都以 `web-` 开头、后面是同一时期的时间戳，**前缀大量相同**，比较时往往要扫过十几个字节才分出大小。

不过在页内二分查找约 9 次比较，这点 CPU 相对一次内存访问几乎可忽略；只有在每秒十万级唯一键校验时才值得计较。

### 3. 插入局部性（取决于数据分布）

索引顺序是 `(user_id, client_token)`，**先按 user_id 排**：

- 不同用户下单 → 插入位置由 user_id 决定，token 是字符串还是整数都改变不了随机性；
- 同一用户连续下单 → token 以时间戳开头，字典序约等于时间序，插入是追加的，局部性不错。这点比纯随机 UUID 好。

所以 **`web-` 前缀对局部性无害，反而因为时间戳在前而有利**。

## 现有设计中已经做对的地方

`V7__order_idempotency.sql` 用的是：

```sql
client_token VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin
```

- `ascii`：1 字符 1 字节，比 `utf8mb4` 省 4 倍；
- `ascii_bin`：按字节直接比较，不走 `utf8mb4_0900_ai_ci` 的权重比较，也避免大小写折叠导致 `ABC` 和 `abc` 被当成同一个键。

这比"用 `utf8mb4_bin` 存 UUID"之类的做法已经高效很多。

## 如果真要优化成 BIGINT

可以做，但要注意：

1. **客户端生成 64 位整数，JS 精度是坑**。`Date.now() << 20` 这类值超过 `Number.MAX_SAFE_INTEGER`（2^53−1），前端必须用 `BigInt` 并序列化成字符串传输，后端再 `Long.parseLong`。项目当前 token 生成逻辑反而简单。
2. **随机位要够**。比如用"秒级时间戳（31 位）+ 22 位随机"，53 位以内 JS 安全，同一用户同一秒碰撞概率约 1/400 万，够用；毫秒级时间戳 + 少量随机位则可能同毫秒重复。
3. **失去可读性**。`web-` 前缀对排查问题（看日志能区分来源）有价值；而 `source` 字段目前还没落库（文档里记为 schema 缺口），前缀算是临时替代。
4. **格式约束要改**。`CreateOrderRequest` 的正则是 `^[A-Za-z0-9_-]{8,64}$`，纯数字字符串也符合，兼容。

另一条路是 **UUIDv7 存 `BINARY(16)`**：16 字节、时间有序，比 26 字节字符串小，但比 `BIGINT` 大一倍，且前端/接口格式都要调整。

## 建议

- **当前阶段保持 `VARCHAR` 完全合理**。26 字节的 key 在千万级订单下索引也就几百 MB，远没到需要为 20 字节纠结的程度。
- **`web-` 前缀只占 4 字节**（千万行约 40MB），换来可读性，划算。
- 如果将来压测发现唯一键校验或索引体积成为瓶颈，再按这个顺序考虑：先缩短 token（去掉前缀、精简随机段）→ 再换 `BIGINT`（用 BigInt 生成）→ 最后才考虑 `BINARY(16)`。
- 顺带一提，`request_hash CHAR(64)` 虽然比 token 长得多，但它**没有建索引**，只占行空间，不影响索引效率；真要对它建索引，才需要改成 `BINARY(32)`（`UNHEX()` 存）。

## 验证方式

在测试库灌 1000 万行两种 key 做对比，看 `information_schema.INNODB_BUFFER_PAGE`、索引页数和压测 QPS，比理论估算可靠。

## 相关文件

- `../common` — `client_token` / `request_hash` 列与唯一索引
- `../common` — 实体字段
- `frontend/src/components/CheckoutModal.vue` — `makeClientToken()`
- `db/README.md` 5.14 节 — 下单幂等设计
- `docs/order-dto-design.md` — 幂等错误码与落地顺序
