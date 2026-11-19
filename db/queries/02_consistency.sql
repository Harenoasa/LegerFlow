-- ============================================================
-- 02 一致性与对账查询
--
-- 全部为只读查询；每个查询返回“有问题的数据行”。
-- 正常样例库上，所有查询的结果都应为空。
--
-- 运行：
--   docker exec -i -e MYSQL_PWD=123123 ledgerflow-mysql \
--     mysql -uroot --default-character-set=utf8mb4 ledgerflow < db/queries/02_consistency.sql
--
-- 背景：本项目默认不建物理外键，跨表一致性由应用层事务 + 这些
--       对账 SQL 兜底。上线后建议把关键查询做成定时巡检。
-- ============================================================

SET NAMES utf8mb4;
USE ledgerflow;

-- 样例数据的“业务当前时间”。用固定值而不是 NOW()，
-- 保证脚本在任何时候执行结论都一致。
SET @ref_now = '2026-10-26 12:00:00.000';

-- ============================================================
-- 1. 订单金额一致性
-- ============================================================

-- 1.1 订单总额应等于明细行金额之和
SELECT o.order_no,
       o.total_amount,
       COALESCE(SUM(oi.item_amount), 0) AS item_total
FROM orders o
LEFT JOIN order_item oi ON oi.order_id = o.id
GROUP BY o.id, o.order_no, o.total_amount
HAVING o.total_amount <> COALESCE(SUM(oi.item_amount), 0);

-- 1.2 应付金额公式：pay = total - discount + freight
SELECT order_no, total_amount, discount_amount, freight_amount, pay_amount
FROM orders
WHERE pay_amount <> total_amount - discount_amount + freight_amount;

-- 1.3 明细行公式：item_amount = unit_price * quantity
--                 pay_amount  = item_amount - discount_amount
SELECT oi.id,
       o.order_no,
       oi.unit_price,
       oi.quantity,
       oi.item_amount,
       oi.discount_amount,
       oi.pay_amount
FROM order_item oi
JOIN orders o ON o.id = oi.order_id
WHERE oi.item_amount <> oi.unit_price * oi.quantity
   OR oi.pay_amount <> oi.item_amount - oi.discount_amount;

-- 1.4 订单级优惠/运费与明细汇总一致
--     本项目把订单级优惠券金额分摊到某条明细的 discount_amount，
--     因此 discount_amount = SUM(item.discount_amount)，
--     pay_amount = SUM(item.pay_amount) + freight_amount。
SELECT o.order_no,
       o.discount_amount,
       COALESCE(SUM(oi.discount_amount), 0) AS item_discount,
       o.pay_amount,
       o.freight_amount,
       COALESCE(SUM(oi.pay_amount), 0)       AS item_pay
FROM orders o
JOIN order_item oi ON oi.order_id = o.id
GROUP BY o.id, o.order_no, o.discount_amount, o.pay_amount, o.freight_amount
HAVING o.discount_amount <> COALESCE(SUM(oi.discount_amount), 0)
    OR o.pay_amount <> COALESCE(SUM(oi.pay_amount), 0) + o.freight_amount;

-- ============================================================
-- 2. 支付一致性
-- ============================================================

-- 2.1 已支付/已发货/已完成/售后中/已退款订单：
--     必须恰好有一笔成功支付，且金额等于订单应付金额。
--     （失败后换渠道重试会产生多条支付单，但成功只能有一条。）
SELECT o.order_no,
       o.order_status,
       o.pay_amount,
       SUM(p.status = 1)                                            AS success_count,
       COALESCE(SUM(CASE WHEN p.status = 1 THEN p.amount END), 0)   AS success_amount
FROM orders o
LEFT JOIN payment_order p ON p.order_no = o.order_no
WHERE o.order_status IN (10, 20, 30, 50, 60)
GROUP BY o.id, o.order_no, o.order_status, o.pay_amount
HAVING SUM(p.status = 1) <> 1
    OR COALESCE(SUM(CASE WHEN p.status = 1 THEN p.amount END), 0) <> o.pay_amount;

-- 2.2 待支付/已取消订单不应存在成功支付
SELECT o.order_no, o.order_status, p.payment_no, p.amount, p.status
FROM orders o
JOIN payment_order p ON p.order_no = o.order_no
WHERE o.order_status IN (0, 40)
  AND p.status = 1;

-- 2.3 支付单自身字段与状态一致
SELECT payment_no, order_no, status, external_trade_no, paid_at, closed_at
FROM payment_order
WHERE (status = 1 AND (paid_at IS NULL OR external_trade_no IS NULL
                       OR paid_at < created_at OR closed_at IS NOT NULL))
   OR (status <> 1 AND paid_at IS NOT NULL)
   OR (status = 3 AND closed_at IS NULL)
   OR status NOT IN (0, 1, 2, 3);

-- ============================================================
-- 3. 退款一致性
-- ============================================================

-- 3.1 同一订单累计退款（申请中/处理中/成功）不能超过实付金额
SELECT r.order_no,
       SUM(r.amount) AS refund_total,
       o.pay_amount
FROM refund_order r
JOIN orders o ON o.order_no = r.order_no
WHERE r.status IN (0, 1, 2)
GROUP BY r.order_no, o.pay_amount
HAVING SUM(r.amount) > o.pay_amount;

-- 3.2 退款单必须关联成功的支付单，且订单号/渠道/用户一致
SELECT r.refund_no,
       r.order_no,
       r.payment_no,
       r.channel,
       r.user_id,
       p.order_no AS pay_order_no,
       p.channel  AS pay_channel,
       p.status   AS pay_status,
       o.user_id  AS order_user_id
FROM refund_order r
JOIN payment_order p ON p.payment_no = r.payment_no
JOIN orders o       ON o.order_no = r.order_no
WHERE p.order_no <> r.order_no
   OR p.channel <> r.channel
   OR p.user_id <> r.user_id
   OR p.status <> 1
   OR o.user_id <> r.user_id;

-- 3.3 退款状态与时间字段一致
SELECT refund_no, status, applied_at, success_at, channel_refund_no
FROM refund_order
WHERE (status = 2 AND (success_at IS NULL
                       OR success_at < applied_at
                       OR channel_refund_no IS NULL))
   OR (status IN (0, 1, 3, 4) AND success_at IS NOT NULL)
   OR status NOT IN (0, 1, 2, 3, 4);

-- ============================================================
-- 4. 库存一致性
--    口径：sold_stock = 已支付订单购买数量；
--          locked_stock = 待支付订单占用数量。
--    “仅退款不退货”不会回补库存，所以退款订单仍计入 sold_stock。
-- ============================================================

-- 4.1 库存计数与订单数量对不上
SELECT i.sku_id,
       i.available_stock,
       i.locked_stock,
       i.sold_stock,
       COALESCE(SUM(CASE WHEN o.order_status IN (10, 20, 30, 50, 60)
                         THEN oi.quantity ELSE 0 END), 0) AS expected_sold,
       COALESCE(SUM(CASE WHEN o.order_status = 0
                         THEN oi.quantity ELSE 0 END), 0) AS expected_locked
FROM inventory i
LEFT JOIN order_item oi ON oi.sku_id = i.sku_id
LEFT JOIN orders o      ON o.id = oi.order_id
GROUP BY i.sku_id, i.available_stock, i.locked_stock, i.sold_stock
HAVING i.sold_stock <> expected_sold
    OR i.locked_stock <> expected_locked;

-- 4.2 库存字段出现负数（CHECK 约束的兜底巡检）
SELECT sku_id, available_stock, locked_stock, sold_stock
FROM inventory
WHERE available_stock < 0 OR locked_stock < 0 OR sold_stock < 0;

-- 4.3 库存流水算术：
--     1 锁定 / 2 解锁：可用库存减 / 加；
--     3 扣减：锁定转已售，可用库存不变；
--     4 回补：退货入库，可用库存增加。
SELECT l.id,
       l.sku_id,
       l.change_type,
       l.change_qty,
       l.before_available,
       l.after_available
FROM inventory_log l
WHERE (l.change_type = 1 AND l.after_available <> l.before_available - l.change_qty)
   OR (l.change_type = 2 AND l.after_available <> l.before_available + l.change_qty)
   OR (l.change_type = 3 AND l.after_available <> l.before_available)
   OR (l.change_type = 4 AND l.after_available <> l.before_available + l.change_qty);

-- 4.4 每个 SKU 最新一条流水的 after_available 应等于当前可用库存
SELECT i.sku_id,
       i.available_stock,
       l.id           AS latest_log_id,
       l.after_available
FROM inventory i
JOIN inventory_log l
  ON l.id = (SELECT MAX(l2.id) FROM inventory_log l2 WHERE l2.sku_id = i.sku_id)
WHERE i.available_stock <> l.after_available;

-- ============================================================
-- 5. 优惠券一致性
-- ============================================================

-- 5.1 模板已领数量应等于用户券实际行数
SELECT ct.id,
       ct.code,
       ct.issued_count,
       COUNT(uc.id) AS actual_issued
FROM coupon_template ct
LEFT JOIN user_coupon uc ON uc.coupon_template_id = ct.id
GROUP BY ct.id, ct.code, ct.issued_count
HAVING ct.issued_count <> COUNT(uc.id);

-- 5.2a 用户券状态与订单核销关系
--      已使用：必须有 order_id、used_at，且订单确实引用这张券；
--      未使用/已过期：不应有 order_id、used_at。
SELECT uc.id AS user_coupon_id,
       uc.user_id,
       uc.status,
       uc.order_id,
       uc.used_at,
       o.id      AS actual_order_id,
       o.user_id AS order_user_id
FROM user_coupon uc
LEFT JOIN orders o ON o.id = uc.order_id
WHERE (uc.status = 1 AND (uc.order_id IS NULL
                          OR uc.used_at IS NULL
                          OR o.id IS NULL
                          OR o.coupon_id <> uc.id
                          OR o.user_id <> uc.user_id))
   OR (uc.status IN (0, 2) AND (uc.order_id IS NOT NULL OR uc.used_at IS NOT NULL));

-- 5.2b 订单引用的券必须存在、已使用、且回指当前订单
SELECT o.id AS order_id,
       o.order_no,
       o.coupon_id,
       uc.status      AS coupon_status,
       uc.order_id    AS coupon_order_id,
       uc.user_id     AS coupon_user_id,
       o.user_id      AS order_user_id
FROM orders o
LEFT JOIN user_coupon uc ON uc.id = o.coupon_id
WHERE o.coupon_id IS NOT NULL
  AND (uc.id IS NULL
       OR uc.status <> 1
       OR uc.order_id <> o.id
       OR uc.user_id <> o.user_id);

-- 5.3 每人领取数量不能超过模板限领数
SELECT uc.user_id,
       uc.coupon_template_id,
       COUNT(*)       AS received_count,
       ct.per_user_limit
FROM user_coupon uc
JOIN coupon_template ct ON ct.id = uc.coupon_template_id
GROUP BY uc.user_id, uc.coupon_template_id, ct.per_user_limit
HAVING COUNT(*) > ct.per_user_limit;

-- 5.4 下单时券必须可用，且优惠金额符合券规则
--     这里的时间校验用订单创建时间，而不是巡检时间。
SELECT o.order_no,
       o.total_amount,
       o.discount_amount,
       ct.code,
       ct.coupon_type,
       ct.threshold_amount,
       CASE
           WHEN ct.coupon_type = 1 THEN ct.discount_amount
           ELSE LEAST(ROUND(o.total_amount * (1 - ct.discount_rate), 2),
                      COALESCE(ct.max_discount_amount, o.total_amount))
       END AS expected_discount
FROM orders o
JOIN user_coupon uc      ON uc.id = o.coupon_id
JOIN coupon_template ct  ON ct.id = uc.coupon_template_id
WHERE o.total_amount < ct.threshold_amount
   OR o.created_at < ct.valid_from
   OR o.created_at > ct.valid_to
   OR uc.expire_at < o.created_at
   OR ABS(o.discount_amount - CASE
        WHEN ct.coupon_type = 1 THEN ct.discount_amount
        ELSE LEAST(ROUND(o.total_amount * (1 - ct.discount_rate), 2),
                   COALESCE(ct.max_discount_amount, o.total_amount))
      END) > 0.005;

-- 5.5 用户券状态与有效期一致
--     未使用但已过期的券，应由过期任务改成“已过期”；
--     状态为已过期但还没到期的，属于提前置位，需要排查。
SELECT uc.id,
       uc.user_id,
       uc.status,
       uc.received_at,
       uc.expire_at
FROM user_coupon uc
WHERE uc.expire_at <= uc.received_at
   OR (uc.status = 0 AND uc.expire_at <= @ref_now)
   OR (uc.status = 2 AND uc.expire_at > @ref_now);

-- ============================================================
-- 6. 状态机与状态日志
-- ============================================================

-- 6.1 订单当前状态必须等于最后一条状态日志的 to_status
SELECT o.order_no,
       o.order_status,
       l.id         AS latest_log_id,
       l.to_status  AS latest_log_to_status
FROM orders o
LEFT JOIN order_status_log l
  ON l.id = (SELECT MAX(l2.id) FROM order_status_log l2 WHERE l2.order_id = o.id)
WHERE l.id IS NULL
   OR l.to_status <> o.order_status;

-- 6.2 状态日志必须是连续链条：
--     第一条 from_status 为 NULL；
--     后一条 from_status 等于前一条 to_status。
WITH chain AS (
    SELECT order_id,
           id,
           from_status,
           to_status,
           LAG(to_status) OVER (PARTITION BY order_id ORDER BY id) AS prev_to_status
    FROM order_status_log
)
SELECT order_id, id, from_status, to_status, prev_to_status
FROM chain
WHERE (prev_to_status IS NULL AND from_status IS NOT NULL)
   OR (prev_to_status IS NOT NULL AND NOT (from_status <=> prev_to_status));

-- 6.3 售后单当前状态必须等于最后一条售后日志
SELECT a.after_sale_no,
       a.status,
       l.id        AS latest_log_id,
       l.to_status AS latest_log_to_status
FROM after_sale_order a
LEFT JOIN after_sale_log l
  ON l.id = (SELECT MAX(l2.id) FROM after_sale_log l2 WHERE l2.after_sale_id = a.id)
WHERE l.id IS NULL
   OR l.to_status <> a.status;

-- 6.4 枚举值巡检（防止绕过应用直接写库写进非法状态）
SELECT 'orders' AS table_name, id, order_status AS bad_value
FROM orders WHERE order_status NOT IN (0, 10, 20, 30, 40, 50, 60)
UNION ALL
SELECT 'payment_order', id, status
FROM payment_order WHERE status NOT IN (0, 1, 2, 3)
UNION ALL
SELECT 'refund_order', id, status
FROM refund_order WHERE status NOT IN (0, 1, 2, 3, 4)
UNION ALL
SELECT 'after_sale_order', id, status
FROM after_sale_order WHERE status NOT IN (0, 1, 2, 3, 4, 5)
UNION ALL
SELECT 'coupon_template', id, coupon_type
FROM coupon_template WHERE coupon_type NOT IN (1, 2)
UNION ALL
SELECT 'user_coupon', id, status
FROM user_coupon WHERE status NOT IN (0, 1, 2)
UNION ALL
SELECT 'order_delivery', id, status
FROM order_delivery WHERE status NOT IN (0, 1, 2, 3)
UNION ALL
SELECT 'payment_callback_log', id, process_status
FROM payment_callback_log WHERE process_status NOT IN (0, 1, 2)
UNION ALL
SELECT 'outbox_event', id, status
FROM outbox_event WHERE status NOT IN (0, 1, 2);

-- ============================================================
-- 7. 订单时间戳与物流
-- ============================================================

-- 7.1 订单时间戳随状态推进，且顺序合理
SELECT order_no,
       order_status,
       created_at,
       pay_time,
       ship_time,
       complete_time,
       cancel_time,
       expire_at
FROM orders
WHERE (order_status IN (10, 20, 30, 50, 60) AND pay_time IS NULL)
   OR (order_status IN (20, 30, 50, 60) AND ship_time IS NULL)
   OR (order_status = 30 AND complete_time IS NULL)
   OR (order_status = 40 AND (cancel_time IS NULL OR cancel_reason IS NULL))
   OR (order_status IN (0, 40) AND pay_time IS NOT NULL)
   OR (pay_time IS NOT NULL AND pay_time < created_at)
   OR (ship_time IS NOT NULL AND (pay_time IS NULL OR ship_time < pay_time))
   OR (complete_time IS NOT NULL AND (ship_time IS NULL OR complete_time < ship_time))
   OR (cancel_time IS NOT NULL AND cancel_time < created_at)
   OR expire_at <= created_at;

-- 7.2 已发货/已完成/售后中/已退款订单必须有物流记录
SELECT o.order_no, o.order_status
FROM orders o
WHERE o.order_status IN (20, 30, 50, 60)
  AND NOT EXISTS (SELECT 1 FROM order_delivery d WHERE d.order_id = o.id);

-- 7.3 物流状态与时间字段一致，且发货不能早于支付
SELECT d.delivery_no,
       d.status,
       d.shipped_at,
       d.delivered_at,
       o.order_no,
       o.pay_time
FROM order_delivery d
JOIN orders o ON o.id = d.order_id
WHERE (d.status IN (1, 2, 3) AND d.shipped_at IS NULL)
   OR (d.status = 3 AND d.delivered_at IS NULL)
   OR (d.delivered_at IS NOT NULL AND d.delivered_at < d.shipped_at)
   OR (o.pay_time IS NOT NULL AND d.shipped_at < o.pay_time);

-- ============================================================
-- 8. 评价与售后关联
-- ============================================================

-- 8.1 评价必须指向本人的、已完成的订单行，且商品信息一致
SELECT pr.id,
       pr.order_item_id,
       pr.order_id,
       pr.user_id,
       pr.spu_id,
       pr.sku_id
FROM product_review pr
LEFT JOIN order_item oi ON oi.id = pr.order_item_id
LEFT JOIN orders o      ON o.id = pr.order_id
WHERE oi.id IS NULL
   OR o.id IS NULL
   OR oi.order_id <> pr.order_id
   OR o.user_id <> pr.user_id
   OR oi.spu_id <> pr.spu_id
   OR oi.sku_id <> pr.sku_id
   OR o.order_status NOT IN (30, 50, 60)
   OR pr.created_at < o.complete_time;

-- 8.2 售后单与订单行、退款单一致
SELECT a.after_sale_no,
       a.order_id,
       a.order_item_id,
       a.user_id,
       a.amount,
       a.status,
       a.refund_no
FROM after_sale_order a
JOIN orders o          ON o.id = a.order_id
JOIN order_item oi     ON oi.id = a.order_item_id
LEFT JOIN refund_order r ON r.refund_no = a.refund_no
WHERE oi.order_id <> a.order_id
   OR o.user_id <> a.user_id
   OR a.amount > oi.pay_amount
   OR (a.refund_no IS NOT NULL AND r.id IS NULL)
   OR (r.id IS NOT NULL AND (r.amount <> a.amount
                             OR r.order_no <> o.order_no
                             OR r.user_id <> a.user_id))
   OR (a.status = 4 AND (r.id IS NULL OR r.status <> 2))
   OR (r.status = 2 AND a.status <> 4);

-- ============================================================
-- 9. 孤儿数据检查（没有物理外键，靠巡检兜底）
--    只输出有问题的关系（cnt > 0）；正常时结果为空。
-- ============================================================

SELECT issue, cnt
FROM (
    SELECT 'user_address.user_id -> users' AS issue, COUNT(*) AS cnt
    FROM user_address c
    WHERE NOT EXISTS (SELECT 1 FROM users p WHERE p.id = c.user_id)
    UNION ALL
    SELECT 'category.parent_id -> category', COUNT(*)
    FROM category c
    WHERE c.parent_id <> 0
      AND NOT EXISTS (SELECT 1 FROM category p WHERE p.id = c.parent_id)
    UNION ALL
    SELECT 'product_spu.category_id -> category', COUNT(*)
    FROM product_spu c
    WHERE NOT EXISTS (SELECT 1 FROM category p WHERE p.id = c.category_id)
    UNION ALL
    SELECT 'product_sku.spu_id -> product_spu', COUNT(*)
    FROM product_sku c
    WHERE NOT EXISTS (SELECT 1 FROM product_spu p WHERE p.id = c.spu_id)
    UNION ALL
    SELECT 'product_image.spu_id -> product_spu', COUNT(*)
    FROM product_image c
    WHERE NOT EXISTS (SELECT 1 FROM product_spu p WHERE p.id = c.spu_id)
    UNION ALL
    SELECT 'inventory.sku_id -> product_sku', COUNT(*)
    FROM inventory c
    WHERE NOT EXISTS (SELECT 1 FROM product_sku p WHERE p.id = c.sku_id)
    UNION ALL
    SELECT 'inventory_log.sku_id -> product_sku', COUNT(*)
    FROM inventory_log c
    WHERE NOT EXISTS (SELECT 1 FROM product_sku p WHERE p.id = c.sku_id)
    UNION ALL
    SELECT 'cart_item.user_id -> users', COUNT(*)
    FROM cart_item c
    WHERE NOT EXISTS (SELECT 1 FROM users p WHERE p.id = c.user_id)
    UNION ALL
    SELECT 'cart_item.sku_id -> product_sku', COUNT(*)
    FROM cart_item c
    WHERE NOT EXISTS (SELECT 1 FROM product_sku p WHERE p.id = c.sku_id)
    UNION ALL
    SELECT 'orders.user_id -> users', COUNT(*)
    FROM orders c
    WHERE NOT EXISTS (SELECT 1 FROM users p WHERE p.id = c.user_id)
    UNION ALL
    SELECT 'orders.coupon_id -> user_coupon', COUNT(*)
    FROM orders c
    WHERE c.coupon_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM user_coupon p WHERE p.id = c.coupon_id)
    UNION ALL
    SELECT 'order_item.order_id -> orders', COUNT(*)
    FROM order_item c
    WHERE NOT EXISTS (SELECT 1 FROM orders p WHERE p.id = c.order_id)
    UNION ALL
    SELECT 'order_item.spu_id -> product_spu', COUNT(*)
    FROM order_item c
    WHERE NOT EXISTS (SELECT 1 FROM product_spu p WHERE p.id = c.spu_id)
    UNION ALL
    SELECT 'order_item.sku_id -> product_sku', COUNT(*)
    FROM order_item c
    WHERE NOT EXISTS (SELECT 1 FROM product_sku p WHERE p.id = c.sku_id)
    UNION ALL
    SELECT 'order_status_log.order_id -> orders', COUNT(*)
    FROM order_status_log c
    WHERE NOT EXISTS (SELECT 1 FROM orders p WHERE p.id = c.order_id)
    UNION ALL
    SELECT 'order_delivery.order_id -> orders', COUNT(*)
    FROM order_delivery c
    WHERE NOT EXISTS (SELECT 1 FROM orders p WHERE p.id = c.order_id)
    UNION ALL
    SELECT 'payment_order.order_no -> orders', COUNT(*)
    FROM payment_order c
    WHERE NOT EXISTS (SELECT 1 FROM orders p WHERE p.order_no = c.order_no)
    UNION ALL
    SELECT 'payment_callback_log.payment_no -> payment_order', COUNT(*)
    FROM payment_callback_log c
    WHERE NOT EXISTS (SELECT 1 FROM payment_order p WHERE p.payment_no = c.payment_no)
    UNION ALL
    SELECT 'refund_order.payment_no -> payment_order', COUNT(*)
    FROM refund_order c
    WHERE NOT EXISTS (SELECT 1 FROM payment_order p WHERE p.payment_no = c.payment_no)
    UNION ALL
    SELECT 'refund_order.order_no -> orders', COUNT(*)
    FROM refund_order c
    WHERE NOT EXISTS (SELECT 1 FROM orders p WHERE p.order_no = c.order_no)
    UNION ALL
    SELECT 'user_coupon.user_id -> users', COUNT(*)
    FROM user_coupon c
    WHERE NOT EXISTS (SELECT 1 FROM users p WHERE p.id = c.user_id)
    UNION ALL
    SELECT 'user_coupon.coupon_template_id -> coupon_template', COUNT(*)
    FROM user_coupon c
    WHERE NOT EXISTS (SELECT 1 FROM coupon_template p WHERE p.id = c.coupon_template_id)
    UNION ALL
    SELECT 'product_review.order_item_id -> order_item', COUNT(*)
    FROM product_review c
    WHERE NOT EXISTS (SELECT 1 FROM order_item p WHERE p.id = c.order_item_id)
    UNION ALL
    SELECT 'product_review.order_id -> orders', COUNT(*)
    FROM product_review c
    WHERE NOT EXISTS (SELECT 1 FROM orders p WHERE p.id = c.order_id)
    UNION ALL
    SELECT 'after_sale_order.order_id -> orders', COUNT(*)
    FROM after_sale_order c
    WHERE NOT EXISTS (SELECT 1 FROM orders p WHERE p.id = c.order_id)
    UNION ALL
    SELECT 'after_sale_order.order_item_id -> order_item', COUNT(*)
    FROM after_sale_order c
    WHERE NOT EXISTS (SELECT 1 FROM order_item p WHERE p.id = c.order_item_id)
    UNION ALL
    SELECT 'after_sale_log.after_sale_id -> after_sale_order', COUNT(*)
    FROM after_sale_log c
    WHERE NOT EXISTS (SELECT 1 FROM after_sale_order p WHERE p.id = c.after_sale_id)
) checks
WHERE cnt > 0;

-- ============================================================
-- 10. 回调与 Outbox
-- ============================================================

-- 10.1 回调日志必须关联真实支付单，渠道一致，处理状态与时间一致
SELECT c.id,
       c.notify_id,
       c.payment_no,
       c.channel,
       c.process_status,
       c.processed_at
FROM payment_callback_log c
LEFT JOIN payment_order p ON p.payment_no = c.payment_no
WHERE p.id IS NULL
   OR p.channel <> c.channel
   OR (c.process_status = 1 AND c.processed_at IS NULL)
   OR (c.process_status IN (0, 2) AND c.processed_at IS NOT NULL);

-- 10.2 Outbox 状态与发布时间一致
SELECT event_id, status, retry_count, next_retry_at, published_at, created_at
FROM outbox_event
WHERE retry_count < 0
   OR (status = 1 AND published_at IS NULL)
   OR (status <> 1 AND published_at IS NOT NULL)
   OR (published_at IS NOT NULL AND published_at < created_at);
