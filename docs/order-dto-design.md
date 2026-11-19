# LedgerFlow 订单 DTO 设计结论

> 基于当前仓库的 Flyway V1–V7 schema（2026-10-27）。
> 目标：为 `POST /api/orders` 定义生产可用的 `CreateOrderRequest` / `CreateOrderResponseDTO` 字段清单。
> 核心原则： **Request 只表达“下单意图”，Response 返回“服务端确认后的事实”**。

## 目录

- [一、数据库里的订单格式](#一数据库里的订单格式)
- [二、生产环境 DTO 的设计原则](#二生产环境-dto-的设计原则)
- [三、Request DTO 字段清单](#三request-dto-字段清单)
- [四、Response DTO 字段清单](#四response-dto-字段清单)
- [五、当前 schema 的生产缺口](#五当前-schema-的生产缺口)
- [六、错误响应 DTO](#六错误响应-dto)
- [七、建议的落地顺序](#七建议的落地顺序)

---

## 一、数据库里的订单格式

订单链路：

```text
orders 1:N order_item
orders 1:N order_status_log
orders 1:N order_delivery
orders 1:N payment_order 1:N refund_order
orders 1:N after_sale_order
order_item 1:0..1 product_review
```

关键点：

- 订单主表保存**收货地址快照**，用户改地址不影响历史订单。
- 订单明细保存**商品名称 / 规格 / 图片 / 单价快照**，商品改价改名不影响历史订单。
- 一个订单允许多次支付尝试，所以 `payment_order.order_no` 不唯一。
- 一个订单允许多个包裹，所以 `order_delivery` 是 1:N。
- 状态用 `TINYINT` + `order_status_log` 记录流转，应用层用条件 UPDATE 推进。

### 1.1 订单主表 `orders`（`V4__orders.sql:13`）

| 字段组 | 字段 | 对外策略 |
|---|---|---|
| 标识 | `id`、`order_no`、`user_id` | `id` / `user_id` 不对外；对外只用 `orderNo`；`userId` 从登录态取 |
| 幂等 | `client_token`、`request_hash`（V7） | 内部字段；创建订单时写入，不对外返回 |
| 状态 | `order_status` | 响应转字符串枚举；请求不允许传 |
| 金额 | `total_amount`、`discount_amount`、`freight_amount`、`pay_amount` | 服务端计算；响应只读返回；请求不收 |
| 优惠 | `coupon_id` | 请求传 `userCouponId`（指向 `user_coupon.id`）；响应返回 `appliedCoupon` |
| 收货快照 | `receiver_name`、`receiver_phone`、`receiver_province`、`receiver_city`、`receiver_district`、`receiver_detail` | 请求只传 `addressId`；服务端从 `user_address` 复制快照 |
| 备注 | `buyer_remark` | 请求可传；响应返回 |
| 时间 | `expire_at`、`pay_time`、`ship_time`、`complete_time`、`cancel_time`、`cancel_reason` | 创建响应只返回 `expireAt` / `createdAt`；其余放详情接口 |
| 并发/审计 | `version`、`created_at`、`updated_at` | `version` 内部；`createdAt` 返回；`updatedAt` 一般不返回 |

### 1.2 订单明细 `order_item`（`V4__orders.sql:49`）

这是**商品快照表，只增不改**：

| 字段 | 说明 | DTO 归属 |
|---|---|---|
| `id` | 订单行主键 | 响应 `orderItemId`（对外当不透明 ID） |
| `order_id` | 内部关联 | 不暴露 |
| `spu_id` / `sku_id` | 商品 / 规格 | 请求只传 `skuId`；响应两个都返回 |
| `product_name` / `sku_spec` / `image_url` | 下单时快照 | 服务端生成；响应返回 |
| `unit_price` | 下单时单价 | 服务端从 `product_sku.price` 快照；请求不收 |
| `quantity` | 购买数量 | 请求唯一数量字段 |
| `item_amount` | `unit_price * quantity` | 服务端算；响应返回 |
| `discount_amount` | 该行分摊优惠 | 服务端算；响应返回 |
| `pay_amount` | `item_amount - discount_amount` | 服务端算；响应返回 |
| `created_at` | 创建时间 | 创建响应通常不需要逐行返回 |

### 1.3 下单会碰到的周边表

| 表 | 迁移文件 | 与下单的关系 |
|---|---|---|
| `user_address` | `V1__user_and_address.sql:35` | 请求传 `addressId`，服务端校验归属并快照 |
| `product_spu` | `V2__catalog.sql:28` | 校验商品上架状态 |
| `product_sku` | `V2__catalog.sql:49` | 读取当前价格、规格、上下架状态 |
| `inventory` | `V3__inventory_and_cart.sql:11` | 条件更新锁定库存 |
| `inventory_log` | `V3__inventory_and_cart.sql:27` | 库存变动流水，业务幂等 |
| `cart_item` | `V3__inventory_and_cart.sql:46` | 购物车结算来源，不存价格 |
| `user_coupon` | `V6__marketing_aftersale_outbox.sql:42` | 用券校验与核销 |
| `coupon_template` | `V6__marketing_aftersale_outbox.sql:14` | 券规则、门槛、折扣 |
| `payment_order` | `V5__payment_and_refund.sql:12` | 支付尝试，可选返回支付单信息 |
| `order_status_log` | `V4__orders.sql:74` | 状态审计，详情接口再返回 |
| `order_delivery` | `V4__orders.sql:89` | 拆包物流，详情接口再返回 |
| `outbox_event` | `V6__marketing_aftersale_outbox.sql:123` | 事务内事件，不对外 |

### 1.4 必须守住的金额不变量（`02_consistency.sql:54-68`）

```text
orders.total_amount          = SUM(order_item.item_amount)
order_item.item_amount       = unit_price * quantity
order_item.pay_amount        = item_amount - discount_amount
orders.pay_amount            = total_amount - discount_amount + freight_amount
orders.pay_amount            = SUM(order_item.pay_amount) + freight_amount
orders.discount_amount       = SUM(order_item.discount_amount)
```

这里有个**生产上很容易踩的坑**：运费是订单级的，不摊到明细。所以：

```text
SUM(items[].payAmount) = order.payAmount - order.freightAmount
```

前端不能简单把明细行 `payAmount` 加起来当订单应付金额，否则有运费时永远差一截。

### 1.5 订单状态机（`db/README.md:402-409`）

```text
0 待支付 → 10 已支付 / 40 已取消
10 已支付 → 20 已发货 / 50 售后中
20 已发货 → 30 已完成 / 50 售后中
50 售后中 → 30 已完成 / 60 已退款
```

状态推进必须使用条件更新：

```sql
UPDATE orders
SET order_status = ?
WHERE id = ? AND order_status = ?;
```

影响 0 行说明状态已变化，不能当失败重试成覆盖写。

---

## 二、生产环境 DTO 的设计原则

1. **请求是意图，响应是事实**：客户端只传 `skuId + quantity`、`addressId`、`userCouponId`，不传价格、金额、状态、快照。
2. **用户身份不从 body 取**：`userId` 从 Token / Session 取，避免越权下单。
3. **金额一律服务端算**：Java 用 `BigDecimal`，`HALF_UP` 保留 2 位，禁止 `double`。
4. **ID 对外用字符串**：`BIGINT UNSIGNED` 可能超过 JS `Number.MAX_SAFE_INTEGER`，`orderNo` 本来也是字符串；`skuId` / `addressId` / `orderItemId` 建议 JSON 输出为 string。
5. **金额也建议输出字符串**：避免前端浮点精度问题，`"1047.00"` 比 `1047.0` 更稳。
6. **时间统一 UTC 存储，API 返回带偏移的 ISO-8601**：如 `2026-10-27T23:00:00+08:00`，并返回 `serverTime` 给前端校准倒计时。
7. **创建订单必须幂等**：靠客户端幂等键 + 数据库唯一约束，不能只靠“先查后插”。
8. **错误用 HTTP 状态码 + 业务错误码**：不要所有响应都 HTTP 200 再包一层 `code`，也不要把 SQL / 堆栈返回给客户端。

### 2.1 DTO 分层速览

```text
CreateOrderRequestDTO
├─ clientToken / Idempotency-Key
├─ addressId
├─ userCouponId
├─ items[]
│  ├─ skuId
│  ├─ quantity
│  └─ cartItemId
├─ buyerRemark
├─ expectedPayAmount
└─ payChannel / source（可选扩展）

CreateOrderResponseDTO
├─ orderNo
├─ orderStatus / orderStatusText
├─ totalAmount / discountAmount / freightAmount / payAmount
├─ totalQuantity
├─ appliedCoupon
├─ receiver
├─ items[]
├─ buyerRemark
├─ expireAt / createdAt / serverTime
├─ payment（可选）
└─ availableActions（可选）
```

---

## 三、Request DTO 字段清单

建议类名保持现有的 `CreateOrderRequest`，嵌套 `CreateOrderItemRequest`。

### 3.1 顶层字段

| 字段 | 类型 | 必填 | 校验 / 取值 | 说明与落库映射 |
|---|---|---|---|---|
| `clientToken` | String | 否* | 8–64，`^[A-Za-z0-9_-]{8,64}$` | 幂等键。建议放 Header `Idempotency-Key`，body 里字段与 Header 二选一；对应 V7 的 `uk_user_client_token(user_id, client_token)` |
| `addressId` | Long（JSON string） | 是 | `> 0` | 查 `user_address`，校验 `user_id = 当前用户` 且 `deleted_at IS NULL`，快照到 `orders.receiver_*` |
| `userCouponId` | Long（JSON string） | 否 | `> 0` | 对应 `orders.coupon_id`，指向 `user_coupon.id`；校验归属、`status=0`、未过期、满足门槛；一单最多一张 |
| `items` | List\<CreateOrderItemRequestDTO\> | 是 | 1–100 行，`@Valid` | 订单明细 |
| `buyerRemark` | String | 否 | ≤ 255，去控制字符 | `orders.buyer_remark` |
| `expectedPayAmount` | BigDecimal（JSON string） | 否 | ≥ 0，两位小数 | 防价格变化：与重算结果不一致返回 `PRICE_CHANGED`，不落库 |
| `payChannel` | String | 否 | `ALIPAY` / `WECHAT` / `BALANCE` | 仅“下单并拉起支付”时用；建议拆到独立支付接口 |
| `source` | String | 否 | ≤ 32 | 下单来源（H5/APP/MINI_PROGRAM）；当前表无列，需后续迁移（V8+）扩展 |

\* `clientToken` 与 Header `Idempotency-Key` 二选一，生产推荐 Header。

### 3.2 `items[]` 字段

| 字段 | 类型 | 必填 | 校验 | 说明 |
|---|---|---|---|---|
| `skuId` | Long（JSON string） | 是 | `> 0` | 服务端据此查 SKU、SPU、库存、当前价 |
| `quantity` | Integer | 是 | 1–999 | 购买数量 |
| `cartItemId` | Long（JSON string） | 否 | `> 0` | 购物车结算时传，用于校验并清理购物车；**不是价格来源** |

### 3.3 这些字段不能出现在 Request 里

| 禁止字段 | 原因 |
|---|---|
| `userId` | 从登录态取，防止越权 |
| `orderNo` | 服务端生成，客户端不能指定 |
| `orderStatus` | 创建时固定 `0`，后续由状态机推进 |
| `totalAmount` / `discountAmount` / `freightAmount` / `payAmount` | 金额必须服务端算，防篡改 |
| `items[].unitPrice` / `itemAmount` / `discountAmount` / `payAmount` | 价格以 SKU 当前价为准 |
| `items[].productName` / `skuSpec` / `imageUrl` | 服务端快照，保证历史订单 |
| `receiverName` / `receiverPhone` / 省市区 / 详址 | 服务端从 `addressId` 快照 |
| `expireAt` | 服务端按规则生成（如 30 分钟） |
| `couponDiscountAmount` | 服务端按券规则计算 |
| `version` | 内部乐观锁 |

> 如果产品要求支持“临时地址 / 不保存到地址簿”，再加一个嵌套 `receiver` 对象，与 `addressId` 二选一；`orders` 存的是快照，表结构本身支持。

### 3.4 Request 示例

```http
POST /api/orders
Authorization: Bearer <token>
Idempotency-Key: 6f1c0f8e-8b7a-4c1d-9e2f-7a6b5c4d3e2f
Content-Type: application/json
```

```json
{
  "addressId": "10001",
  "userCouponId": "20001",
  "items": [
    { "skuId": "3", "quantity": 1, "cartItemId": "501" },
    { "skuId": "5", "quantity": 2 }
  ],
  "buyerRemark": "请工作日送达",
  "expectedPayAmount": "1047.00"
}
```

### 3.5 Bean Validation 建议

```java
@NotNull @Positive
Long addressId;

@NotEmpty @Size(max = 100) @Valid
List<CreateOrderItemRequestDTO> items;

@Min(1) @Max(999)
Integer quantity;

@Size(max = 255)
String buyerRemark;

@DecimalMin("0.00") @Digits(integer = 16, fraction = 2)
BigDecimal expectedPayAmount;

@Pattern(regexp = "^[A-Za-z0-9_-]{8,64}$")
String clientToken;
```

---

## 四、Response DTO 字段清单

建议类名保持 `CreateOrderResponseDTO`，嵌套 `OrderItemDTO`、`ReceiverDTO`、`AppliedCouponDTO`、`PaymentInfoDTO`。

### 4.1 顶层字段

| 字段 | 类型 | 必返 | 来源 / 说明 |
|---|---|---|---|
| `orderNo` | String | 是 | `orders.order_no`，服务端用雪花算法生成的对外唯一标识，格式为 `LF + 雪花数字` |
| `orderStatus` | String | 是 | 字符串枚举，见 4.3；不要直接暴露 DB 数字 |
| `orderStatusText` | String | 否 | 展示文案；建议前端按枚举映射，服务端返回仅作兜底 |
| `totalAmount` | BigDecimal（string） | 是 | `orders.total_amount` |
| `discountAmount` | BigDecimal（string） | 是 | `orders.discount_amount` |
| `freightAmount` | BigDecimal（string） | 是 | `orders.freight_amount` |
| `payAmount` | BigDecimal（string） | 是 | `orders.pay_amount`，支付页以此为准 |
| `totalQuantity` | Integer | 是 | `SUM(order_item.quantity)` 派生 |
| `appliedCoupon` | AppliedCouponDTO | 否 | 用了券才返回 |
| `receiver` | ReceiverDTO | 是 | 订单快照，不是当前地址 |
| `items` | List\<OrderItemDTO\> | 是 | 订单明细快照 |
| `buyerRemark` | String | 是 | 无备注返回 `""` |
| `expireAt` | String（ISO-8601） | 是 | 支付截止时间 |
| `createdAt` | String（ISO-8601） | 是 | 下单时间 |
| `serverTime` | String（ISO-8601） | 是 | 服务端当前时间，前端用于倒计时校准 |
| `payment` | PaymentInfoDTO | 否 | 同时创建支付单时返回 |
| `availableActions` | List\<String\> | 否 | 如 `["PAY","CANCEL"]`，前端按钮直接用 |

### 4.2 嵌套 DTO

#### ReceiverDTO（来自 `orders.receiver_*` 快照）

| 字段 | 类型 | 必返 | 说明 |
|---|---|---|---|
| `receiverName` | String | 是 | 收货人 |
| `receiverPhone` | String | 是 | 完整手机号仅返回给订单所有者；日志和非本人查询必须脱敏 |
| `province` | String | 是 | 省 |
| `city` | String | 是 | 市 |
| `district` | String | 是 | 区/县 |
| `detailAddress` | String | 是 | 详细地址 |

> `orders` 没有 `postal_code` 快照；需要邮编就加后续迁移（V8+）字段，不要在 Response 里凭空返回当前地址的邮编。

#### OrderItemDTO

| 字段 | 类型 | 必返 | 说明 |
|---|---|---|---|
| `orderItemId` | Long（string） | 是 | `order_item.id` |
| `spuId` | Long（string） | 是 | `order_item.spu_id` |
| `skuId` | Long（string） | 是 | `order_item.sku_id` |
| `productName` | String | 是 | 快照 |
| `skuSpec` | String | 是 | 快照 |
| `imageUrl` | String | 是 | 快照 |
| `unitPrice` | BigDecimal（string） | 是 | 快照 |
| `quantity` | Integer | 是 | 数量 |
| `itemAmount` | BigDecimal（string） | 是 | `unit_price * quantity` |
| `discountAmount` | BigDecimal（string） | 是 | 该行分摊优惠 |
| `payAmount` | BigDecimal（string） | 是 | `item_amount - discount_amount` |

#### AppliedCouponDTO

| 字段 | 类型 | 必返 | 说明 |
|---|---|---|---|
| `userCouponId` | Long（string） | 是 | `user_coupon.id` |
| `couponName` | String | 是 | 当前需 join `coupon_template.name`；建议做订单快照，见第五节 |
| `couponType` | String | 是 | `FULL_REDUCTION` / `DISCOUNT` |
| `discountAmount` | BigDecimal（string） | 是 | 本单实际优惠金额 |

#### PaymentInfoDTO（可选）

| 字段 | 类型 | 必返 | 说明 |
|---|---|---|---|
| `paymentNo` | String | 是 | `payment_order.payment_no` |
| `channel` | String | 是 | `ALIPAY` / `WECHAT` / `BALANCE` |
| `status` | String | 是 | `PENDING` / `SUCCESS` / `FAILED` / `CLOSED` |
| `amount` | BigDecimal（string） | 是 | 支付金额 |
| `expireAt` | String | 是 | 支付截止时间 |
| `payParams` | Map / String | 是 | 渠道 SDK 参数；不要落库、不要打日志 |

### 4.3 订单状态枚举映射（`db/README.md:253`）

| DB `order_status` | API 枚举 | 中文 |
|---:|---|---|
| `0` | `PENDING_PAYMENT` | 待支付 |
| `10` | `PAID` | 已支付 |
| `20` | `SHIPPED` | 已发货 |
| `30` | `COMPLETED` | 已完成 |
| `40` | `CANCELLED` | 已取消 |
| `50` | `AFTER_SALE` | 售后中 |
| `60` | `REFUNDED` | 已退款 |

建议 API 用字符串枚举，DB 的 `TINYINT` 只在持久层出现。如果前端已按数字写死，至少同时返回 `orderStatus`（数字）和 `orderStatusText`，不要让前端猜。

### 4.4 不建议返回的字段

| 字段 | 原因 |
|---|---|
| `id` | 自增主键，不对外 |
| `userId` | 隐私 / 越权风险 |
| `version` | 内部并发控制 |
| `couponId` | 用 `appliedCoupon.userCouponId`，不要暴露模板 ID |
| `receiverAddressId` | 快照已足够 |
| `payment.externalTradeNo` | 渠道敏感信息，创建阶段不需要 |
| `statusLogs` / `deliveries` / `refunds` | 详情接口再返回 |
| `inventory` / `inventoryLog` / `outboxEvent` | 内部实现 |

### 4.5 Response 示例

```json
{
  "orderNo": "LF373271725637632000",
  "orderStatus": "PENDING_PAYMENT",
  "orderStatusText": "待支付",
  "totalAmount": "1097.00",
  "discountAmount": "50.00",
  "freightAmount": "0.00",
  "payAmount": "1047.00",
  "totalQuantity": 3,
  "appliedCoupon": {
    "userCouponId": "20001",
    "couponName": "新人满100减50",
    "couponType": "FULL_REDUCTION",
    "discountAmount": "50.00"
  },
  "receiver": {
    "receiverName": "张三",
    "receiverPhone": "13800000001",
    "province": "广东省",
    "city": "深圳市",
    "district": "南山区",
    "detailAddress": "科技园路 1 号"
  },
  "buyerRemark": "请工作日送达",
  "items": [
    {
      "orderItemId": "1001",
      "spuId": "2",
      "skuId": "3",
      "productName": "静界 Air 无线降噪耳机",
      "skuSpec": "曜石黑",
      "imageUrl": "https://cdn.example.com/products/spu02-headphone.jpg",
      "unitPrice": "899.00",
      "quantity": 1,
      "itemAmount": "899.00",
      "discountAmount": "40.98",
      "payAmount": "858.02"
    },
    {
      "orderItemId": "1002",
      "spuId": "3",
      "skuId": "5",
      "productName": "基础款纯棉 T 恤",
      "skuSpec": "白色 / L",
      "imageUrl": "https://cdn.example.com/products/spu03-tshirt.jpg",
      "unitPrice": "99.00",
      "quantity": 2,
      "itemAmount": "198.00",
      "discountAmount": "9.02",
      "payAmount": "188.98"
    }
  ],
  "expireAt": "2026-10-27T23:00:00+08:00",
  "createdAt": "2026-10-27T10:00:00+08:00",
  "serverTime": "2026-10-27T10:00:00+08:00",
  "availableActions": ["PAY", "CANCEL"]
}
```

注意示例里的优惠是按商品行金额比例分摊的（`40.98 + 9.02 = 50.00`）。当前 `seed.sql` 是把整单优惠落在一条明细上（`02_consistency.sql:55`），两种都满足数据库约束；生产更推荐按比例 + 最大余数法，避免某一行优惠超过行金额。

### 4.6 如果复用为订单详情

创建响应之外，详情接口可在此基础上增加：

- `payTime` / `shipTime` / `completeTime` / `cancelTime` / `cancelReason`
- `deliveries[]`：`deliveryNo`、`carrierCode`、`carrierName`、`trackingNo`、`status`、`shippedAt`、`deliveredAt`
- `payments[]`：`paymentNo`、`channel`、`amount`、`status`、`paidAt`（不返回 `externalTradeNo`）
- `refunds[]`：`refundNo`、`amount`、`status`、`appliedAt`、`successAt`
- `afterSales[]`：`afterSaleNo`、`afterSaleType`、`amount`、`status`
- `refundedAmount`：从 `refund_order` 聚合，或后续冗余到 `orders`
- `statusLogs[]`：`fromStatus`、`toStatus`、`operatorType`、`reason`、`createdAt`
- `availableActions`：`PAY`、`CANCEL`、`CONFIRM_RECEIPT`、`REFUND`、`REVIEW` 等

---

## 五、当前 schema 的生产缺口

| 生产要求 | 当前 schema | 建议 |
|---|---|---|
| 创建订单幂等 | V7 已加 `orders.client_token`、`request_hash`、`UNIQUE(user_id, client_token)` | 应用层强制要求 token，并记录 `request_hash`；如需记录失败尝试/缓存响应，再考虑独立 `order_idempotency` 表 |
| 优惠券快照 | 只有 `orders.coupon_id` + `discount_amount` | 后续迁移（V8+）加 `coupon_name` / `coupon_snapshot` JSON；否则券模板改名/删除后历史订单展示会变 |
| 下单来源 | 无 `order_source` | 需要统计/风控就加后续迁移（V8+） |
| 结算报价 / 防价格变化 | 无 quote 表 | 先加 `expectedPayAmount` 轻量校验；正式做 `/orders/preview` + `quoteToken` |
| 收货邮编快照 | `user_address.postal_code` 有，`orders` 没有 | 需要就加 `receiver_postal_code` |
| 已退款金额 | 只能从 `refund_order` 聚合 | 列表/详情频繁用时加 `orders.refunded_amount` 冗余 |
| 发票 | 无表 | 独立 `order_invoice` 表 |
| 多币种 | 无 `currency` | 当前单币种 CNY 可忽略；要做再加 |
| 明细行号 | 只有 `order_item.id` | 对外用 `orderItemId` 即可；要可读行号再加 `item_no` |
| 优惠分摊规则 | 应用层自由 | 建议按 `item_amount` 比例 + 最大余数法，保证 `SUM(item.discount) = order.discount` |
| 运费分摊 | 订单级 | 不摊到明细；前端务必用 `order.payAmount`，不要累加明细 |

### 5.1 落地时最容易出错的几个点

1. **幂等不是“先查再插”**：并发下会双写。用 V7 的 `uk_user_client_token` 兜底，捕获 `DuplicateKeyException` 后查询已存在订单返回；同一 token 不同请求体返回 `IDEMPOTENCY_KEY_CONFLICT`。
2. **优惠券是双向引用**：`orders.coupon_id` ↔ `user_coupon.order_id`。按 `db/README.md:173-179` 的顺序：先插订单（`coupon_id = NULL`）→ 核销券并拿到 `user_coupon.id` → 回填 `orders.coupon_id`。
3. **库存按 skuId 排序后逐行条件更新**：

   ```sql
   UPDATE inventory
   SET available_stock = available_stock - ?,
       locked_stock = locked_stock + ?
   WHERE sku_id = ?
     AND available_stock >= ?;
   ```

   同时写 `inventory_log`（`biz_no = order_no`，`change_type = 1`），都放在同一事务。
4. **价格以提交时 SKU 当前价为准**：先校验 `product_sku.status = 1 AND deleted_at IS NULL`、`product_spu.status = 1 AND deleted_at IS NULL`，再快照 `price`。
5. **支付渠道预下单是外部调用**：不要放在创建订单的数据库事务里。建议创建订单事务提交后，再走独立支付接口，避免长事务和外部超时拖垮数据库。
6. **日志脱敏**：请求体里的手机号、地址、`payParams`、Token 不要原样打日志；响应给非本人时手机号脱敏为 `138****0001`。
7. **优惠分摊取整**：按行金额比例计算后，用最大余数法处理分币，最后一行吸收差额，保证 `SUM(item.discount_amount) = order.discount_amount`，且每行 `discount_amount <= item_amount`。
8. **Outbox 与业务同事务**：创建订单、扣库存、核销券、写 `order_status_log`、写 `outbox_event` 必须在同一个数据库事务里，避免“订单成功、消息丢失”。

### 5.2 建议的下单事务顺序

```text
1. 校验幂等键（唯一索引 / 幂等表）
2. 校验地址归属、SKU 上架状态、优惠券归属与有效期
3. 计算金额（SKU 当前价、运费、优惠）
4. 插入 orders（order_status=0，coupon_id=NULL，expire_at=now+30m）
5. 插入 order_item（商品快照、优惠分摊）
6. 按 skuId 升序逐行条件扣库存 + 写 inventory_log
7. 条件核销 user_coupon（status=0 → 1）+ 回填 orders.coupon_id
8. 写 order_status_log（from_status=NULL，to_status=0）
9. 写 outbox_event（ORDER_CREATED）
10. COMMIT
11. 事务外：如需支付，调用渠道预下单并创建 payment_order
```

---

## 六、错误响应 DTO

建议所有非 2xx 响应统一结构，或使用 Spring 的 `ProblemDetail` 并扩展 `code` / `traceId`：

| 字段 | 类型 | 说明 |
|---|---|---|
| `code` | String | 业务错误码 |
| `message` | String | 可读提示 |
| `traceId` | String | 链路 ID，便于排查 |
| `timestamp` | String | ISO-8601 |
| `errors` | List\<FieldError\> | 参数校验明细（`field` / `message`），可选 |
| `details` | Map | 结构化上下文，如 `skuId`、`availableStock`、`latestPayAmount` |

| HTTP | `code` | 场景 |
|---:|---|---|
| 400 | `VALIDATION_FAILED` | Bean Validation 失败 |
| 401 | `UNAUTHORIZED` | 未登录 / Token 失效 |
| 403 | `ADDRESS_FORBIDDEN` / `COUPON_FORBIDDEN` | 地址或券不属于当前用户 |
| 404 | `ADDRESS_NOT_FOUND` / `SKU_NOT_FOUND` | 地址/SKU 不存在 |
| 409 | `SKU_OFF_SHELF` | SKU 或 SPU 已下架 |
| 409 | `OUT_OF_STOCK` | 库存不足，`details` 带 `skuId`、`availableStock` |
| 409 | `COUPON_INVALID` / `COUPON_EXPIRED` / `COUPON_THRESHOLD_NOT_MET` | 券不可用 |
| 409 | `PRICE_CHANGED` | `expectedPayAmount` 与重算结果不一致，`details` 返回最新金额 |
| 409 | `IDEMPOTENCY_KEY_CONFLICT` | 同一幂等键对应不同请求体 |
| 429 | `RATE_LIMITED` | 下单频率限制 |
| 500 | `INTERNAL_ERROR` | 未预期异常，不返回堆栈/SQL |

创建成功建议返回 **201 Created**，并带 `Location: /api/orders/{orderNo}`；幂等重放返回 **200 OK** + Header `Idempotent-Replayed: true`。

---

## 七、建议的落地顺序

先跑通链路，只实现最小字段集：

**Request 最小集**

```text
addressId
items[].skuId
items[].quantity
userCouponId? 
buyerRemark?
Idempotency-Key
```

**Response 最小集**

```text
orderNo
orderStatus
totalAmount
discountAmount
freightAmount
payAmount
receiver
items[]
expireAt
createdAt
```

然后再补：

1. V7 已完成：`client_token` / `request_hash` + `uk_user_client_token` 唯一索引；接下来接应用层幂等流程
2. `expectedPayAmount` 价格校验
3. `appliedCoupon`、`totalQuantity`、`serverTime`、`availableActions`
4. 支付单与 `payment` 嵌套对象
5. 优惠券快照、下单来源、发票等 V8+ 扩展

---

## 附录：DTO 类结构建议

```text
com.harenoasa.ledgerflowcommon.dto.request
├─ CreateOrderRequestDTO
└─ CreateOrderItemRequestDTO

com.harenoasa.ledgerflowcommon.dto.response
├─ CreateOrderResponseDTO
├─ OrderItemDTO
├─ ReceiverDTO
├─ AppliedCouponDTO
└─ PaymentInfoDTO

com.harenoasa.ledgerflowcommon.enums
├─ OrderStatusEnum
├─ CouponTypeEnum
├─ PayChannelEnum
└─ PaymentStatusEnum

com.harenoasa.ledgerflowcommon.common
├─ ApiErrorResponse
└─ FieldErrorDTO
```

序列化建议：

- `BigDecimal` → JSON string，2 位小数。
- `Long`（BIGINT UNSIGNED）→ JSON string，避免 JS 精度丢失。
- `Instant` / `OffsetDateTime` → ISO-8601 带偏移，内部统一 UTC。
- 枚举 → 字符串，不从 DB `TINYINT` 直接透传。
