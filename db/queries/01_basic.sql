-- ============================================================
-- 01 基础查询：分页、订单详情、商品列表、购物车、优惠券、全文搜索
--
-- 全部为只读查询，可反复执行。
-- 运行：
--   docker exec -i -e MYSQL_PWD=123123 ledgerflow-mysql \
--     mysql -uroot --default-character-set=utf8mb4 ledgerflow < db/queries/01_basic.sql
--
-- 说明：mysql 命令行不支持 LIMIT @变量（预处理语句才支持 ? 占位符），
--       因此脚本中的 LIMIT 使用字面量，实际 Java/MyBatis 代码用 #{limit}。
-- ============================================================

SET NAMES utf8mb4;
USE ledgerflow;

-- ============================================================
-- 1. “我的订单”游标分页（seek pagination）
--    索引：idx_user_created (user_id, created_at DESC, id DESC)
--    不用 OFFSET：翻页越深越慢，而且新订单插入会导致重复/漏行。
--    游标 = 上一页最后一行的 (created_at, id)。
-- ============================================================

-- 用户 1 共有 2 笔订单；这里把页大小设为 1，方便演示第二页。
SET @user_id = 1;

-- 第一页：最新一笔
SELECT order_no, order_status, pay_amount, created_at, id
FROM orders
WHERE user_id = @user_id
ORDER BY created_at DESC, id DESC
LIMIT 1;

-- 应用把第一页最后一行的 (created_at, id) 作为下一页游标传回。
-- 这里手动指定，等价于第一页返回的 LF202610260001 / 2026-10-26 05:00:00.000 / 1。
SET @cursor_created_at = '2026-10-26 05:00:00.000';
SET @cursor_id = 1;

-- 第二页：严格小于游标。
-- 行构造器 (created_at, id) < (?, ?) 语义正确，但 MySQL 8.4 在
-- DESC 联合索引上可能退化成“索引扫描 + Filter”；展开成 OR 形式
-- 可以稳定走索引范围扫描。id 用于 created_at 相同时的 tie-breaker。
SELECT order_no, order_status, pay_amount, created_at, id
FROM orders
WHERE user_id = @user_id
  AND (created_at < @cursor_created_at
       OR (created_at = @cursor_created_at AND id < @cursor_id))
ORDER BY created_at DESC, id DESC
LIMIT 1;

-- 对比：OFFSET 分页在数据量大时要做“扫描后丢弃”，越翻越慢。
SELECT order_no, order_status, pay_amount, created_at, id
FROM orders
WHERE user_id = @user_id
ORDER BY created_at DESC, id DESC
LIMIT 1 OFFSET 1;

-- ============================================================
-- 2. 订单详情：主表 + 明细聚合 + 支付尝试 + 物流 + 状态日志
--    以已完成的 LF202609050001 为例（2 个商品、1 次成功支付、已签收）。
-- ============================================================

SET @order_no = 'LF202609050001';

-- 2.1 订单主表（含用户信息和收货地址快照）
SELECT o.order_no,
       o.order_status,
       u.username,
       o.receiver_name,
       o.receiver_phone,
       CONCAT(o.receiver_province, o.receiver_city, o.receiver_district, o.receiver_detail) AS receiver_address,
       o.total_amount,
       o.discount_amount,
       o.freight_amount,
       o.pay_amount,
       o.created_at,
       o.pay_time,
       o.complete_time
FROM orders o
JOIN users u ON u.id = o.user_id
WHERE o.order_no = @order_no;

-- 2.2 订单明细（商品名称/规格/单价都是下单时快照）
SELECT oi.id,
       oi.spu_id,
       oi.sku_id,
       oi.product_name,
       oi.sku_spec,
       oi.unit_price,
       oi.quantity,
       oi.item_amount,
       oi.discount_amount,
       oi.pay_amount
FROM order_item oi
JOIN orders o ON o.id = oi.order_id
WHERE o.order_no = @order_no
ORDER BY oi.id;

-- 2.3 主表金额与明细汇总是否一致（正常应相等）
SELECT o.order_no,
       o.total_amount,
       SUM(oi.item_amount) AS item_total,
       o.discount_amount,
       SUM(oi.discount_amount) AS item_discount,
       o.pay_amount,
       SUM(oi.pay_amount) AS item_pay
FROM orders o
JOIN order_item oi ON oi.order_id = o.id
WHERE o.order_no = @order_no
GROUP BY o.id, o.order_no, o.total_amount, o.discount_amount, o.pay_amount;

-- 2.4 支付尝试：一个订单可能有多条（失败后换渠道重试）
SELECT payment_no, channel, amount, status, external_trade_no, expire_at, paid_at
FROM payment_order
WHERE order_no = @order_no
ORDER BY id;

-- 2.5 物流包裹（支持拆包，因此是 1:N）
SELECT delivery_no, carrier_name, tracking_no, status, shipped_at, delivered_at
FROM order_delivery
WHERE order_id = (SELECT id FROM orders WHERE order_no = @order_no)
ORDER BY id;

-- 2.6 状态流转审计
SELECT id, from_status, to_status, operator_type, operator_id, reason, created_at
FROM order_status_log
WHERE order_id = (SELECT id FROM orders WHERE order_no = @order_no)
ORDER BY id;

-- ============================================================
-- 3. 分类商品列表
--    聚合时注意 ONLY_FULL_GROUP_BY：非聚合列必须出现在 GROUP BY 中，
--    或由主键函数决定（这里 c.id 是主键，c.name/c.sort 依赖它）。
-- ============================================================

-- 3.1 每个一级分类的 SPU/SKU 数量、价格区间、可售库存
SELECT c.id,
       c.name,
       COUNT(DISTINCT s.id) AS spu_count,
       COUNT(k.id)          AS sku_count,
       MIN(k.price)         AS min_price,
       MAX(k.price)         AS max_price,
       COALESCE(SUM(i.available_stock), 0) AS available_stock
FROM category c
LEFT JOIN product_spu s
       ON s.category_id = c.id AND s.status = 1 AND s.deleted_at IS NULL
LEFT JOIN product_sku k
       ON k.spu_id = s.id AND k.status = 1 AND k.deleted_at IS NULL
LEFT JOIN inventory i
       ON i.sku_id = k.id
WHERE c.status = 1
GROUP BY c.id, c.name
ORDER BY c.sort, c.id;

-- 3.2 数码分类（category_id=1）的商品列表：SPU + 可售 SKU
SELECT s.id           AS spu_id,
       s.title,
       s.brand,
       k.id           AS sku_id,
       k.sku_no,
       k.spec_summary,
       k.price,
       k.original_price,
       i.available_stock
FROM product_spu s
JOIN product_sku k ON k.spu_id = s.id AND k.status = 1 AND k.deleted_at IS NULL
JOIN inventory i   ON i.sku_id = k.id
WHERE s.category_id = 1
  AND s.status = 1
  AND s.deleted_at IS NULL
ORDER BY s.id, k.price;

-- ============================================================
-- 4. 购物车结算预览
--    购物车不保存价格：结算时重新读取 SKU 当前价格和库存。
-- ============================================================

SELECT ci.id,
       ci.sku_id,
       s.title,
       k.spec_summary,
       ci.quantity,
       k.price                              AS current_price,
       k.price * ci.quantity                AS line_amount,
       i.available_stock,
       CASE
           WHEN k.status <> 1 OR k.deleted_at IS NOT NULL THEN '已下架'
           WHEN i.available_stock < ci.quantity THEN '库存不足'
           ELSE '可购买'
       END                                  AS stock_check
FROM cart_item ci
JOIN product_sku k ON k.id = ci.sku_id
JOIN product_spu s ON s.id = k.spu_id
JOIN inventory i   ON i.sku_id = ci.sku_id
WHERE ci.user_id = 1
ORDER BY ci.updated_at DESC;

-- ============================================================
-- 5. 用户可用优惠券
--    使用前还要校验：门槛、有效期、是否已用、是否属于当前用户。
-- ============================================================

SELECT uc.id,
       ct.code,
       ct.name,
       ct.coupon_type,
       ct.discount_amount,
       ct.discount_rate,
       ct.threshold_amount,
       ct.max_discount_amount,
       uc.status,
       uc.received_at,
       uc.expire_at
FROM user_coupon uc
JOIN coupon_template ct ON ct.id = uc.coupon_template_id
WHERE uc.user_id = 4
  AND uc.status = 0
  AND uc.expire_at > '2026-10-26 12:00:00.000'
ORDER BY uc.expire_at;

-- ============================================================
-- 6. 中文全文搜索（ngram 全文索引 ft_title）
--    注意：ngram_token_size 默认 2，单字搜索通常无法命中。
-- ============================================================

SELECT id, title, brand
FROM product_spu
WHERE MATCH(title) AGAINST('耳机' IN BOOLEAN MODE)
  AND status = 1
  AND deleted_at IS NULL;

SELECT id, title, brand
FROM product_spu
WHERE MATCH(title) AGAINST('咖啡' IN BOOLEAN MODE)
  AND status = 1
  AND deleted_at IS NULL;
