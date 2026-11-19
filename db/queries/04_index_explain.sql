-- ============================================================
-- 04 索引与执行计划（EXPLAIN）
--
-- 目标：看清“索引为什么能用、为什么没被用、用到了多少行”。
--
-- 只读业务表；第 5 节会在当前会话创建临时表 demo_orders，
-- 造 5 万行数据演示深分页，结束时删除。临时表不影响业务表，
-- 换一个连接就消失，可反复执行本文件。
--
-- 运行（必须整文件执行，临时表才跨语句存在）：
--   docker exec -i -e MYSQL_PWD=123123 ledgerflow-mysql \
--     mysql -uroot --default-character-set=utf8mb4 ledgerflow < db/queries/04_index_explain.sql
--
-- EXPLAIN 关键列：
--   type:  const(唯一键等值) > ref(普通等值) > range(范围)
--          > index(全索引扫描) > ALL(全表扫描)
--   key:   实际选中的索引
--   rows:  优化器估算需要检查的行数（不是精确值）
--   Extra: Using index          覆盖索引，不回表
--          Using index condition 索引下推（ICP）
--          Using filesort        需要额外排序
--          Using temporary       需要临时表（常见于 GROUP BY）
--
-- 注意：seed 只有 15 笔订单，数据量太小，优化器有时会选全表扫描。
--       第 5 节用 5 万行临时表还原真实数据量下的行为。
-- ============================================================

SET NAMES utf8mb4;
USE ledgerflow;

SET @now = '2026-10-26 12:00:00.000';

-- ============================================================
-- 1. 用户订单列表：索引同时满足 WHERE 和 ORDER BY
--
-- 索引 idx_user_created (user_id, created_at DESC, id DESC)
-- 与查询的过滤、排序、分页完全对齐，因此不需要 filesort。
-- ============================================================

EXPLAIN
SELECT order_no, order_status, pay_amount, created_at, id
FROM orders
WHERE user_id = 1
ORDER BY created_at DESC, id DESC
LIMIT 20;

-- 预期：type=ref，key=idx_user_created，Extra 为空（没有 Using filesort）。
-- 对比：换一个不在索引里的排序字段，就需要把该用户的订单全部取出再排序。

EXPLAIN
SELECT order_no, order_status, pay_amount, created_at, id
FROM orders
WHERE user_id = 1
ORDER BY pay_amount DESC
LIMIT 20;

-- 预期：Extra 出现 Using filesort。
-- 数据量大时，排序可能在磁盘上进行，深分页会更慢。

-- ============================================================
-- 2. 超时关单扫描：联合索引的“等值 + 范围”顺序
--
-- 索引 idx_status_expire (order_status, expire_at) 的第一列做等值，
-- 第二列做范围，正好匹配定时任务的查询。
-- ============================================================

EXPLAIN
SELECT id
FROM orders
WHERE order_status = 0
  AND expire_at <= @now
ORDER BY expire_at
LIMIT 100;

-- 预期：type=range，key=idx_status_expire，Extra 含 Using index。
-- 只查 id 时，二级索引本身已包含主键，不需要回表（覆盖索引）。

EXPLAIN
SELECT id, buyer_remark
FROM orders
WHERE order_status = 0
  AND expire_at <= @now
ORDER BY expire_at
LIMIT 100;

-- 预期：Extra 不再有 Using index（buyer_remark 不在索引里），
-- 需要按主键回表读取整行。

-- ============================================================
-- 3. 支付回调幂等：唯一键的等值查找
--
-- uk_channel_notify (channel, notify_id) 既是业务约束，
-- 也是查询入口。回调处理必须先按这两个字段查重。
-- ============================================================

EXPLAIN
SELECT id, payment_no, channel, process_status
FROM payment_callback_log
WHERE channel = 'WECHAT'
  AND notify_id = 'N202610050002';

-- 预期：type=const，key=uk_channel_notify。
-- 唯一键等值命中，最多一行，代价最低。

EXPLAIN
SELECT id, payment_no, channel, process_status
FROM payment_callback_log
WHERE notify_id = 'N202610050002';

-- 预期：type=index 或 ALL，无法按唯一键定位。
-- 原因：联合索引的最左前缀是 channel，只给 notify_id 用不上。
-- 这也是为什么应用层查重必须带上 channel（或把 notify_id 设计为全局唯一）。

-- ============================================================
-- 4. 中文全文搜索：全文索引 vs LIKE '%...%'
--
-- ft_title 使用 ngram 解析器，适合“包含某个词”的商品搜索。
-- B-Tree 索引无法加速前置通配符 LIKE。
-- ============================================================

EXPLAIN
SELECT id, title, brand
FROM product_spu
WHERE MATCH(title) AGAINST('耳机' IN BOOLEAN MODE)
  AND status = 1
  AND deleted_at IS NULL;

-- 预期：type=fulltext，key=ft_title。
-- ngram_token_size 默认为 2，单个汉字通常无法命中。

EXPLAIN
SELECT id, title, brand
FROM product_spu
WHERE title LIKE '%耳机%'
  AND status = 1
  AND deleted_at IS NULL;

-- 预期：type=ALL，key=NULL，全表扫描。
-- 前置 % 让 B-Tree 无法确定搜索起点。

-- ============================================================
-- 5. 深分页：OFFSET vs 游标（5 万行临时表）
--
-- 业务数据量小时两种写法看不出差别，这里造 5 万行同一用户的订单，
-- 对比“翻到第 2500 页”时数据库实际读了多少行。
-- ============================================================

SET SESSION cte_max_recursion_depth = 100000;

DROP TEMPORARY TABLE IF EXISTS demo_orders;
CREATE TEMPORARY TABLE demo_orders LIKE orders;

INSERT INTO demo_orders
    (order_no, user_id, order_status, total_amount, discount_amount,
     freight_amount, pay_amount, receiver_name, receiver_phone,
     receiver_province, receiver_city, receiver_district, receiver_detail,
     expire_at, created_at, updated_at)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 50000
)
SELECT CONCAT('DEMO', LPAD(n, 10, '0')),
       1,
       30,
       100.00,
       0.00,
       0.00,
       100.00,
       'demo',
       '13800000000',
       '省',
       '市',
       '区',
       '演示地址',
       '2026-10-26 00:00:00.000',
       TIMESTAMPADD(SECOND, n, '2026-01-01 00:00:00'),
       TIMESTAMPADD(SECOND, n, '2026-01-01 00:00:00')
FROM seq;

SELECT COUNT(*) AS demo_rows FROM demo_orders;

-- 5.1 取出第 2500 页的游标（生产中就是上一页最后一行的值）。
--     两条 SELECT 都带 OFFSET，它们本身也要扫描 49980 行——
--     这正好说明 OFFSET 的代价。
SET @cursor_created_at = (
    SELECT created_at FROM demo_orders
    ORDER BY created_at DESC, id DESC LIMIT 1 OFFSET 49979
);
SET @cursor_id = (
    SELECT id FROM demo_orders
    ORDER BY created_at DESC, id DESC LIMIT 1 OFFSET 49979
);

-- 5.2 OFFSET 写法：先按索引顺序取出 50000 行，再丢弃前 49980 行
EXPLAIN ANALYZE
SELECT order_no, created_at, id
FROM demo_orders
WHERE user_id = 1
ORDER BY created_at DESC, id DESC
LIMIT 20 OFFSET 49980;

-- 预期：Limit/Offset 下层索引查找 rows=50000，
-- 实际耗时明显更高（本地约几十毫秒，数据量越大越慢）。

-- 5.3 游标写法：把“跳过”变成索引范围条件，只读需要的一小段
EXPLAIN ANALYZE
SELECT order_no, created_at, id
FROM demo_orders
WHERE user_id = 1
  AND (created_at < @cursor_created_at
       OR (created_at = @cursor_created_at AND id < @cursor_id))
ORDER BY created_at DESC, id DESC
LIMIT 20;

-- 预期：Index range scan，actual rows 约 20，
-- 耗时通常比 OFFSET 低两个数量级。
--
-- 说明：行构造器 (created_at, id) < (?, ?) 语义相同，但在 MySQL 8.4
-- 的 DESC 联合索引上可能退化成“索引查找 + Filter”（仍会读很多行）。
-- 因此示例使用展开的 OR 写法，让优化器稳定走范围扫描。

DROP TEMPORARY TABLE demo_orders;

-- ============================================================
-- 6. 索引失效：对列做函数运算
-- ============================================================

EXPLAIN
SELECT id
FROM orders
WHERE DATE(created_at) = '2026-10-26';

-- 预期：type=index（全索引扫描）或 ALL，无法使用范围扫描。
-- 因为 DATE(created_at) 是计算后的值，索引里没有这个结果。

EXPLAIN
SELECT id
FROM orders
WHERE created_at >= '2026-10-26 00:00:00.000'
  AND created_at <  '2026-10-27 00:00:00.000';

-- 预期：type=range，key=idx_created_at。
-- 把“对列计算”改成“对常量计算”，索引就能用上。

-- ============================================================
-- 小结
--   1) 联合索引按“等值列在前、范围列在后”设计。
--   2) ORDER BY 的列顺序尽量与索引一致，避免 filesort。
--   3) 只查索引里有的列，争取 Using index（覆盖索引）。
--   4) 唯一键既保证约束，也是最高效的查询入口。
--   5) 深分页用游标，不要用大 OFFSET。
--   6) WHERE 里不要对列做函数/表达式运算。
-- ============================================================
