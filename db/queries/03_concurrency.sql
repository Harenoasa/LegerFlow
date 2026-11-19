-- ============================================================
-- 03 并发与幂等演示
--
-- 目标：用一条条可执行的 SQL 看清“并发下为什么会错、条件更新怎么救”。
--
-- 所有写操作都包在 START TRANSACTION ... ROLLBACK 里，执行完数据
-- 不会变化，可以反复运行。演示假设 seed.sql 的初始状态。
--
-- 运行：
--   docker exec -i -e MYSQL_PWD=123123 ledgerflow-mysql \
--     mysql -uroot --default-character-set=utf8mb4 ledgerflow < db/queries/03_concurrency.sql
--
-- 单独观察双会话阻塞：开两个终端，各自执行
--   docker exec -it -e MYSQL_PWD=123123 ledgerflow-mysql \
--     mysql -uroot --default-character-set=utf8mb4 ledgerflow
-- 然后按每节的“双会话”注释依次输入。
--
-- 关键工具：ROW_COUNT() 返回上一条语句实际影响的行数。
--   UPDATE ... WHERE 条件不满足 → 0 行
--   INSERT IGNORE 命中唯一键     → 0 行
-- 应用代码应把 0 行当作“状态已变化/消息已处理”，而不是当成失败重试。
-- ============================================================

SET NAMES utf8mb4;
USE ledgerflow;

-- 业务当前时间，固定值保证演示可重复。
SET @now = '2026-10-26 12:00:00.000';

-- ============================================================
-- 1. 防超卖：单条条件 UPDATE
--
-- 正确写法把“判断 + 扣减”合并成一条原子语句，InnoDB 会对该行加锁，
-- 并在锁释放后重新判断 WHERE，不存在“先查后改”的丢更新。
-- ============================================================

-- SKU 17 当前 available_stock = 297。
START TRANSACTION;

-- 1.1 正常购买 1 件
UPDATE inventory
SET available_stock = available_stock - 1,
    locked_stock    = locked_stock + 1,
    version         = version + 1
WHERE sku_id = 17
  AND available_stock >= 1;

SELECT ROW_COUNT() AS buy_one_affected;   -- 1

ROLLBACK;

-- 1.2 购买量超过库存：WHERE 不成立，更新 0 行
START TRANSACTION;

UPDATE inventory
SET available_stock = available_stock - 99999,
    locked_stock    = locked_stock + 99999,
    version         = version + 1
WHERE sku_id = 17
  AND available_stock >= 99999;

SELECT ROW_COUNT() AS oversell_affected;  -- 0 → 应用返回“库存不足”

ROLLBACK;

-- 错误示范（不要执行）：先查后改。
--   请求 A、B 都读到 297，各自算出 296 再写回，最终只卖出 1 件。
--   UPDATE inventory SET available_stock = @stock_seen - 1 WHERE sku_id = 17;
--
-- 双会话演示：
--   会话 A: BEGIN; UPDATE ... SET available_stock = available_stock - 1 ...;（不提交）
--   会话 B: BEGIN; 执行同样的 UPDATE;  -- 阻塞在行锁上
--   会话 A: COMMIT;
--   会话 B: 被唤醒，基于最新值重新判断 WHERE，再决定影响 0 行还是 1 行。

-- ============================================================
-- 2. 乐观锁：version 字段 + 重试
--
-- 适合“读多写少”或需要先做复杂业务判断的场景：
--   读出 version → 业务计算 → UPDATE ... WHERE version = 读到的值
-- 影响 0 行说明期间被别人改过，应用重新读取再试。
-- ============================================================

START TRANSACTION;

SELECT available_stock, version
INTO @stock_seen, @version_seen
FROM inventory
WHERE sku_id = 17;

-- 2.1 第一次更新：版本匹配
UPDATE inventory
SET available_stock = @stock_seen - 1,
    locked_stock    = locked_stock + 1,
    version         = version + 1
WHERE sku_id = 17
  AND version = @version_seen;

SELECT ROW_COUNT() AS optimistic_first;   -- 1

-- 2.2 另一个线程拿着同一个旧版本号提交：版本已变，更新 0 行
UPDATE inventory
SET available_stock = @stock_seen - 2,
    locked_stock    = locked_stock + 2,
    version         = version + 1
WHERE sku_id = 17
  AND version = @version_seen;

SELECT ROW_COUNT() AS optimistic_stale;   -- 0 → 应用重新读取后重试

ROLLBACK;

-- ============================================================
-- 3. 订单状态机：条件更新 + 重复回调
--
-- 状态只能沿合法边流转；把“期望的当前状态”写进 WHERE，
-- 重复请求和非法流转都会自然影响 0 行。
--
-- 合法边（示例）：
--   0 待支付 → 10 已支付 / 40 已取消
--   10 已支付 → 20 已发货 / 50 售后中
--   20 已发货 → 30 已完成 / 50 售后中
-- ============================================================

START TRANSACTION;

-- 3.1 支付回调：支付单从“待支付”置为“成功”
--     同时校验金额，防止渠道回调金额被篡改。
UPDATE payment_order
SET status            = 1,
    external_trade_no = 'WX2026102600001',
    paid_at           = @now
WHERE payment_no = 'PAY202610260001'
  AND status = 0
  AND amount = 5999.00;

SELECT ROW_COUNT() AS pay_claimed;        -- 1

-- 3.2 订单从“待支付”推进到“已支付”
UPDATE orders
SET order_status = 10,
    pay_time     = @now,
    version      = version + 1
WHERE order_no = 'LF202610260001'
  AND order_status = 0;

SELECT ROW_COUNT() AS order_paid;         -- 1

-- 3.3 渠道重复通知：支付单已经不是 0，更新 0 行
UPDATE payment_order
SET status            = 1,
    external_trade_no = 'WX2026102600001',
    paid_at           = @now
WHERE payment_no = 'PAY202610260001'
  AND status = 0
  AND amount = 5999.00;

SELECT ROW_COUNT() AS duplicate_callback; -- 0 → 直接返回成功，不重复处理

-- 3.4 非法流转：已支付订单不能再按“待支付”路径取消
UPDATE orders
SET order_status = 40,
    cancel_time  = @now,
    cancel_reason = '用户取消',
    version      = version + 1
WHERE order_no = 'LF202610260001'
  AND order_status = 0;

SELECT ROW_COUNT() AS invalid_cancel;     -- 0 → 状态机拦住了

ROLLBACK;

-- ============================================================
-- 4. 重复支付回调：唯一键幂等闸门
--
-- payment_callback_log 上的 uk_channel_notify(channel, notify_id)
-- 让“同一渠道的同一通知”只能落一条记录。
-- ============================================================

START TRANSACTION;

SET @notify_id = 'NOTIFY-DEMO-20261026-0001';

-- 4.1 第一次收到通知
INSERT IGNORE INTO payment_callback_log
    (notify_id, payment_no, channel, raw_body, process_status, processed_at, created_at)
VALUES
    (@notify_id, 'PAY202610260001', 'WECHAT', '{"demo": true}', 1, @now, @now);

SELECT ROW_COUNT() AS first_notify;       -- 1

-- 4.2 渠道重试，notify_id 相同：唯一键挡住，插入 0 行
INSERT IGNORE INTO payment_callback_log
    (notify_id, payment_no, channel, raw_body, process_status, processed_at, created_at)
VALUES
    (@notify_id, 'PAY202610260001', 'WECHAT', '{"demo": true}', 1, @now, @now);

SELECT ROW_COUNT() AS duplicate_notify;   -- 0 → 返回成功，不再执行业务

ROLLBACK;

-- 如果不用 INSERT IGNORE 而直接 INSERT，第二次会报：
--   ERROR 1062 (23000): Duplicate entry ... for key 'uk_channel_notify'
-- 应用捕获 DuplicateKeyException 后仍应向渠道返回成功，避免无限重试。

-- ============================================================
-- 5. 优惠券：领取防超发、使用防重复
-- ============================================================

-- 5.1 领取：UPDATE ... WHERE issued_count < total_count
--     为了在初始数据上演示“领完”，事务内临时把总量改成只剩 1 张。
START TRANSACTION;

UPDATE coupon_template
SET total_count = issued_count + 1
WHERE id = 1;                             -- NEW20：临时只剩 1 张

-- 用户 7 领取
UPDATE coupon_template
SET issued_count = issued_count + 1
WHERE id = 1
  AND issued_count < total_count;

SELECT ROW_COUNT() AS first_claim;        -- 1

-- 用户 8 再领：已发完
UPDATE coupon_template
SET issued_count = issued_count + 1
WHERE id = 1
  AND issued_count < total_count;

SELECT ROW_COUNT() AS sold_out_claim;     -- 0

ROLLBACK;

-- 注意：这条语句只防“总量超发”。
-- “每人限领 per_user_limit 张”需要额外检查：
--   SELECT COUNT(*) FROM user_coupon
--   WHERE user_id = ? AND coupon_template_id = ?;  -- 在同一事务内，必要时 FOR UPDATE
-- 或用 Redis 原子计数；对账 SQL 02 的 5.3 会兜底发现超领。

-- 5.2 使用：UPDATE ... WHERE status = 0
--     同一张券并发使用两次，只有第一次能成功。
START TRANSACTION;

-- 用户 4 的 NEW20（user_coupon.id = 2），下单时占用
-- 真实代码在同一事务里还会插入订单，并把 orders.coupon_id 指回这张券。
UPDATE user_coupon
SET status  = 1,
    used_at = @now,
    order_id = 4
WHERE id = 2
  AND user_id = 4
  AND status = 0
  AND expire_at > @now;

SELECT ROW_COUNT() AS first_use;          -- 1

UPDATE user_coupon
SET status  = 1,
    used_at = @now,
    order_id = 4
WHERE id = 2
  AND user_id = 4
  AND status = 0
  AND expire_at > @now;

SELECT ROW_COUNT() AS duplicate_use;      -- 0 → 并发下的第二个请求失败

ROLLBACK;

-- ============================================================
-- 6. 库存流水幂等：先插流水，再改库存
--
-- inventory_log 的 uk_biz(biz_type, biz_no, sku_id, change_type)
-- 让同一条业务消息只能落一条流水。消息重复投递时，
-- INSERT IGNORE 影响 0 行，应用直接 return，不再动库存。
-- ============================================================

START TRANSACTION;

-- 6.1 支付成功：锁定转已售（SKU 1 当前 locked_stock = 1）
--     先把流水当幂等闸门插入，成功后才更新计数。
INSERT IGNORE INTO inventory_log
    (sku_id, change_type, change_qty, before_available, after_available,
     biz_type, biz_no, remark, created_at)
VALUES
    (1, 3, 1, 99, 99, 'ORDER_PAY', 'PAY202610260001', '支付成功：锁定转已售', @now);

SELECT ROW_COUNT() AS first_log;          -- 1 → 首次消费

UPDATE inventory
SET locked_stock = locked_stock - 1,
    sold_stock   = sold_stock + 1,
    version      = version + 1
WHERE sku_id = 1
  AND locked_stock >= 1;

SELECT ROW_COUNT() AS stock_updated;      -- 1

-- 6.2 消息中间件重复投递同一条消息
INSERT IGNORE INTO inventory_log
    (sku_id, change_type, change_qty, before_available, after_available,
     biz_type, biz_no, remark, created_at)
VALUES
    (1, 3, 1, 99, 99, 'ORDER_PAY', 'PAY202610260001', '支付成功：锁定转已售', @now);

SELECT ROW_COUNT() AS duplicate_log;      -- 0 → 应用 return，库存不会再扣

ROLLBACK;

-- 顺序很重要：
--   先插流水（幂等闸门）再改库存，且两者必须在同一事务里。
--   如果先改库存再插流水，中间崩溃会丢一次扣减；
--   如果流水和库存更新不在同一事务，闸门就失效了。

-- ============================================================
-- 7. 超时关单：条件更新抢单 + 释放锁定库存 + 写审计日志
--
-- 定时任务可能多实例同时跑。先用订单状态条件更新“抢到关单权”，
-- 只有 ROW_COUNT() = 1 的实例继续释放库存。
-- ============================================================

START TRANSACTION;

SET @timeout_order_no = 'LF202610200001'; -- 已过期但仍待支付，locked_stock 仍占着

-- 7.1 抢占关单权：状态 + 过期时间同时校验
UPDATE orders
SET order_status  = 40,
    cancel_time   = @now,
    cancel_reason = '支付超时自动关闭',
    version       = version + 1
WHERE order_no = @timeout_order_no
  AND order_status = 0
  AND expire_at <= @now;

SELECT ROW_COUNT() AS claimed;            -- 1 → 本实例负责关单

-- 7.2 释放该订单占用的锁定库存（一单多商品时可影响多行）
UPDATE inventory i
JOIN order_item oi ON oi.sku_id = i.sku_id
JOIN orders o      ON o.id = oi.order_id
SET i.available_stock = i.available_stock + oi.quantity,
    i.locked_stock    = i.locked_stock - oi.quantity,
    i.version         = i.version + 1
WHERE o.order_no = @timeout_order_no
  AND i.locked_stock >= oi.quantity;

SELECT ROW_COUNT() AS released_skus;      -- 1

-- 7.3 解锁流水：before 59 → after 60（SKU 2）
INSERT IGNORE INTO inventory_log
    (sku_id, change_type, change_qty, before_available, after_available,
     biz_type, biz_no, remark, created_at)
VALUES
    (2, 2, 1, 59, 60, 'ORDER_CANCEL', @timeout_order_no, '超时关单释放库存', @now);

SELECT ROW_COUNT() AS unlock_log;         -- 1

-- 7.4 状态审计
INSERT INTO order_status_log
    (order_id, from_status, to_status, operator_type, operator_id, reason, created_at)
VALUES
    (2, 0, 40, 3, 0, '支付超时自动关闭', @now);

SELECT ROW_COUNT() AS status_log;         -- 1

-- 7.5 另一个任务实例随后也扫到这笔订单：状态已是 40，抢不到
UPDATE orders
SET order_status  = 40,
    cancel_time   = @now,
    cancel_reason = '支付超时自动关闭',
    version       = version + 1
WHERE order_no = @timeout_order_no
  AND order_status = 0
  AND expire_at <= @now;

SELECT ROW_COUNT() AS second_worker;      -- 0 → 不会重复释放库存

ROLLBACK;

-- 生产补充：
--   * 扫描用 idx_status_expire(order_status, expire_at)：
--       SELECT id FROM orders
--       WHERE order_status = 0 AND expire_at <= NOW(3)
--       ORDER BY expire_at LIMIT 100;
--   * 多实例可以进一步用 SELECT ... FOR UPDATE SKIP LOCKED 分批抢任务。
--   * 关单、释放库存、写日志、写 outbox 必须在一个事务里；
--     任何一步失败都整体回滚，下一轮任务会重新扫到这笔订单。

-- ============================================================
-- 演示结束：所有事务均已回滚，数据库回到 seed 初始状态。
-- ============================================================
