-- ============================================================
-- LedgerFlow demo 数据重置脚本
--
-- 作用：只清空 23 张业务表的 demo 数据，保留表结构、索引、
--       Flyway 历史（flyway_schema_history）和迁移版本记录。
-- 适用：本地开发/学习环境。执行后可以重新导入 seed.sql。
--
-- 导入命令：
--   docker exec -i -e MYSQL_PWD=123123 ledgerflow-mysql \
--     mysql -uroot --default-character-set=utf8mb4 ledgerflow < db/demo/reset.sql
--
-- 注意：
--   1. 本脚本会删除全部业务数据，不要在生产库执行。
--   2. 删除顺序按逻辑依赖倒序排列。若执行过 db/optional/foreign_keys.sql，
--      orders.coupon_id 与 user_coupon.order_id 的循环引用会让“先删券”
--      或“先删订单”都违反外键；脚本会先把两侧的可空引用置 NULL，
--      再按顺序删除，所以有无物理外键都能运行。
--   3. DELETE 不会重置 AUTO_INCREMENT；seed.sql 总是显式指定
--      主键，因此重复“reset + seed”后 id 仍然固定。
--   4. 如需连表结构一起重来，请使用（危险，会删数据卷）：
--        docker compose down -v && docker compose up -d
--      然后重新启动应用让 Flyway 重建表。
-- ============================================================

SET NAMES utf8mb4;
USE ledgerflow;

START TRANSACTION;

-- 解除循环引用（orders.coupon_id <-> user_coupon.order_id）：
-- orders 还引用着券，券也还引用着订单，直接删任一方向都会违反外键。
-- 两侧都可空，先置 NULL 即可；没有物理外键时这两条也无副作用。
UPDATE orders      SET coupon_id = NULL;
UPDATE user_coupon SET order_id  = NULL;

-- 基础设施 / 售后 / 营销
DELETE FROM processed_event;
DELETE FROM outbox_event;
DELETE FROM after_sale_log;
DELETE FROM after_sale_order;
DELETE FROM product_review;
DELETE FROM user_coupon;
DELETE FROM coupon_template;

-- 支付 / 退款
DELETE FROM refund_order;
DELETE FROM payment_callback_log;
DELETE FROM payment_order;

-- 订单 / 物流
DELETE FROM order_delivery;
DELETE FROM order_status_log;
DELETE FROM order_item;
DELETE FROM orders;

-- 购物车 / 库存
DELETE FROM cart_item;
DELETE FROM inventory_log;
DELETE FROM inventory;

-- 商品
DELETE FROM product_image;
DELETE FROM product_sku;
DELETE FROM product_spu;
DELETE FROM category;

-- 用户
DELETE FROM user_address;
DELETE FROM users;

COMMIT;

-- 校验：以下每一行都应为 0
SELECT 'users' AS table_name, COUNT(*) AS remaining FROM users
UNION ALL SELECT 'user_address', COUNT(*) FROM user_address
UNION ALL SELECT 'category', COUNT(*) FROM category
UNION ALL SELECT 'product_spu', COUNT(*) FROM product_spu
UNION ALL SELECT 'product_sku', COUNT(*) FROM product_sku
UNION ALL SELECT 'product_image', COUNT(*) FROM product_image
UNION ALL SELECT 'inventory', COUNT(*) FROM inventory
UNION ALL SELECT 'inventory_log', COUNT(*) FROM inventory_log
UNION ALL SELECT 'cart_item', COUNT(*) FROM cart_item
UNION ALL SELECT 'orders', COUNT(*) FROM orders
UNION ALL SELECT 'order_item', COUNT(*) FROM order_item
UNION ALL SELECT 'order_status_log', COUNT(*) FROM order_status_log
UNION ALL SELECT 'order_delivery', COUNT(*) FROM order_delivery
UNION ALL SELECT 'payment_order', COUNT(*) FROM payment_order
UNION ALL SELECT 'payment_callback_log', COUNT(*) FROM payment_callback_log
UNION ALL SELECT 'refund_order', COUNT(*) FROM refund_order
UNION ALL SELECT 'coupon_template', COUNT(*) FROM coupon_template
UNION ALL SELECT 'user_coupon', COUNT(*) FROM user_coupon
UNION ALL SELECT 'product_review', COUNT(*) FROM product_review
UNION ALL SELECT 'after_sale_order', COUNT(*) FROM after_sale_order
UNION ALL SELECT 'after_sale_log', COUNT(*) FROM after_sale_log
UNION ALL SELECT 'outbox_event', COUNT(*) FROM outbox_event
UNION ALL SELECT 'processed_event', COUNT(*) FROM processed_event;
