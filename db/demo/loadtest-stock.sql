-- ============================================================
-- 压测库存预置脚本
--
-- 作用：把所有 SKU 的可售库存统一拉到 10000000，避免多轮压测
--       因 available_stock 被锁完而大量返回 OUT_OF_STOCK。
--
-- 用法（每轮压测前执行一次，可重复执行）：
--   docker exec -i -e MYSQL_PWD=123123 ledgerflow-mysql \
--     mysql -uroot --default-character-set=utf8mb4 ledgerflow < db/demo/loadtest-stock.sql
--
-- 说明：
--   1. 只调整 available_stock，保留 locked_stock / sold_stock 的历史口径。
--   2. 每轮执行都会把可售库存重置回 1000 万，保证压测起点一致、结果可比。
--   3. 压测产生的订单会继续占用 locked_stock、并写入 orders / inventory_log；
--      如需完全干净的数据，先执行 reset.sql + seed.sql，再执行本脚本。
--   4. available_stock 是 INT（上限 2147483647），1000 万足够本地多轮压测；
--      不要调到接近上限，避免后续扣减时溢出。
--   5. 该 UPDATE 不改 inventory_log。压测关注吞吐/延迟，不需要补齐回补流水；
--      如果在意库存流水与库存余额的一致性，跑完后 reset + seed 恢复演示数据。
-- ============================================================

SET NAMES utf8mb4;
USE ledgerflow;

UPDATE inventory
SET available_stock = 10000000;

-- 校验：所有 SKU 的 available_stock 都应为 10000000
SELECT sku_id, available_stock, locked_stock, sold_stock
FROM inventory
ORDER BY sku_id;
