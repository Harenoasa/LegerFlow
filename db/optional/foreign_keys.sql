-- ============================================================
-- 可选：物理外键（学习用，默认不执行）
--
-- 默认 schema 刻意不建物理外键，一致性靠应用层事务 + 对账 SQL。
-- 本文件把 34 条逻辑关系补成真实外键，用来亲手观察：
--   1. 插入/删除顺序如何被数据库强制；
--   2. 循环引用（orders.coupon_id <-> user_coupon.order_id）有多麻烦；
--   3. 外键要求子表列有索引，MySQL 会“悄悄”自动建索引；
--   4. 为什么互联网业务常把一致性放在应用层，而不是数据库。
--
-- 建议顺序：Flyway 建表 -> 导入 seed -> 再执行本文件。
-- 这样脚本会在“已有数据”上校验一遍；有孤儿数据会直接报错。
--
-- 执行（只执行一次，重复执行会因索引/约束已存在而报错）：
--   docker exec -i -e MYSQL_PWD=123123 ledgerflow-mysql \
--     mysql -uroot --default-character-set=utf8mb4 ledgerflow < db/optional/foreign_keys.sql
--
-- 移除：见文件末尾第 8 节（默认是注释，需手动取消注释执行）。
--
-- 约束策略：ON DELETE RESTRICT / ON UPDATE RESTRICT（MySQL 默认）。
-- 不用 CASCADE：删除一笔订单时静默级联删掉明细、支付、退款太危险；
-- 也不用 SET NULL：会掩盖业务层忘记清理数据的问题。
-- 业务号（order_no / payment_no / refund_no）约定不可变，所以 UPDATE 也 RESTRICT。
-- ============================================================

SET NAMES utf8mb4;
USE ledgerflow;

-- ============================================================
-- 0. 子表索引：外键列必须先有索引
--
-- InnoDB 要求外键列在子表上有索引；如果没有，MySQL 会自动
-- 创建一个（名字由约束名/列名生成，事后容易忘记它从哪来）。
-- 这里显式建好 8 个缺失的索引，名字可控。
-- 其余外键列已有可用索引（见各表 idx_* / uk_*）。
--
-- 注意：移除外键不会自动删除这些索引，需要单独判断是否保留。
-- ============================================================

ALTER TABLE cart_item         ADD INDEX idx_cart_sku (sku_id);
ALTER TABLE orders            ADD INDEX idx_orders_coupon (coupon_id);
ALTER TABLE payment_order     ADD INDEX idx_payment_user (user_id);
ALTER TABLE refund_order      ADD INDEX idx_refund_user (user_id);
ALTER TABLE product_review    ADD INDEX idx_review_order (order_id);
ALTER TABLE product_review    ADD INDEX idx_review_spu (spu_id, created_at);
ALTER TABLE after_sale_order  ADD INDEX idx_after_sale_item (order_item_id);
ALTER TABLE after_sale_order  ADD INDEX idx_after_sale_refund (refund_no);

-- ============================================================
-- 1. 用户与商品
-- ============================================================

ALTER TABLE user_address
    ADD CONSTRAINT fk_address_user
        FOREIGN KEY (user_id) REFERENCES users (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE product_spu
    ADD CONSTRAINT fk_spu_category
        FOREIGN KEY (category_id) REFERENCES category (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE product_sku
    ADD CONSTRAINT fk_sku_spu
        FOREIGN KEY (spu_id) REFERENCES product_spu (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE product_image
    ADD CONSTRAINT fk_image_spu
        FOREIGN KEY (spu_id) REFERENCES product_spu (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

-- ============================================================
-- 2. 库存与购物车
-- ============================================================

ALTER TABLE inventory
    ADD CONSTRAINT fk_inventory_sku
        FOREIGN KEY (sku_id) REFERENCES product_sku (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE inventory_log
    ADD CONSTRAINT fk_invlog_sku
        FOREIGN KEY (sku_id) REFERENCES product_sku (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE cart_item
    ADD CONSTRAINT fk_cart_user
        FOREIGN KEY (user_id) REFERENCES users (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE cart_item
    ADD CONSTRAINT fk_cart_sku
        FOREIGN KEY (sku_id) REFERENCES product_sku (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

-- ============================================================
-- 3. 订单链路
--
-- orders.coupon_id 与 user_coupon.order_id 构成环，
-- 但“加约束”本身不受影响（现有数据两个方向都成立）。
-- 受影响的是写入顺序，见第 6 节。
-- ============================================================

ALTER TABLE orders
    ADD CONSTRAINT fk_order_user
        FOREIGN KEY (user_id) REFERENCES users (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE orders
    ADD CONSTRAINT fk_order_coupon
        FOREIGN KEY (coupon_id) REFERENCES user_coupon (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE order_item
    ADD CONSTRAINT fk_item_order
        FOREIGN KEY (order_id) REFERENCES orders (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE order_item
    ADD CONSTRAINT fk_item_spu
        FOREIGN KEY (spu_id) REFERENCES product_spu (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE order_item
    ADD CONSTRAINT fk_item_sku
        FOREIGN KEY (sku_id) REFERENCES product_sku (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE order_status_log
    ADD CONSTRAINT fk_statuslog_order
        FOREIGN KEY (order_id) REFERENCES orders (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE order_delivery
    ADD CONSTRAINT fk_delivery_order
        FOREIGN KEY (order_id) REFERENCES orders (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

-- ============================================================
-- 4. 支付与退款
--
-- 这里演示“外键也可以引用非主键的唯一键”：
--   支付单/退款单用业务号关联订单，而不是订单自增 id。
-- 代价是业务号必须始终唯一且不可修改（ON UPDATE RESTRICT），
-- 并且两侧的类型、字符集、collation 必须完全一致，否则 errno 150。
-- ============================================================

ALTER TABLE payment_order
    ADD CONSTRAINT fk_payment_order_no
        FOREIGN KEY (order_no) REFERENCES orders (order_no)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE payment_order
    ADD CONSTRAINT fk_payment_user
        FOREIGN KEY (user_id) REFERENCES users (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE payment_callback_log
    ADD CONSTRAINT fk_callback_payment
        FOREIGN KEY (payment_no) REFERENCES payment_order (payment_no)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE refund_order
    ADD CONSTRAINT fk_refund_payment
        FOREIGN KEY (payment_no) REFERENCES payment_order (payment_no)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE refund_order
    ADD CONSTRAINT fk_refund_order_no
        FOREIGN KEY (order_no) REFERENCES orders (order_no)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE refund_order
    ADD CONSTRAINT fk_refund_user
        FOREIGN KEY (user_id) REFERENCES users (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

-- ============================================================
-- 5. 营销、评价与售后
-- ============================================================

ALTER TABLE user_coupon
    ADD CONSTRAINT fk_user_coupon_user
        FOREIGN KEY (user_id) REFERENCES users (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE user_coupon
    ADD CONSTRAINT fk_user_coupon_template
        FOREIGN KEY (coupon_template_id) REFERENCES coupon_template (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE user_coupon
    ADD CONSTRAINT fk_user_coupon_order
        FOREIGN KEY (order_id) REFERENCES orders (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE product_review
    ADD CONSTRAINT fk_review_item
        FOREIGN KEY (order_item_id) REFERENCES order_item (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE product_review
    ADD CONSTRAINT fk_review_order
        FOREIGN KEY (order_id) REFERENCES orders (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE product_review
    ADD CONSTRAINT fk_review_user
        FOREIGN KEY (user_id) REFERENCES users (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE product_review
    ADD CONSTRAINT fk_review_spu
        FOREIGN KEY (spu_id) REFERENCES product_spu (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE product_review
    ADD CONSTRAINT fk_review_sku
        FOREIGN KEY (sku_id) REFERENCES product_sku (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE after_sale_order
    ADD CONSTRAINT fk_aftersale_order
        FOREIGN KEY (order_id) REFERENCES orders (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE after_sale_order
    ADD CONSTRAINT fk_aftersale_item
        FOREIGN KEY (order_item_id) REFERENCES order_item (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE after_sale_order
    ADD CONSTRAINT fk_aftersale_user
        FOREIGN KEY (user_id) REFERENCES users (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE after_sale_order
    ADD CONSTRAINT fk_aftersale_refund
        FOREIGN KEY (refund_no) REFERENCES refund_order (refund_no)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

ALTER TABLE after_sale_log
    ADD CONSTRAINT fk_aftersale_log
        FOREIGN KEY (after_sale_id) REFERENCES after_sale_order (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT;

-- ============================================================
-- 6. 循环引用：orders.coupon_id <-> user_coupon.order_id
--
-- MySQL 的外键检查是“立即生效”的（没有 Oracle 那种 DEFERRABLE），
-- 所以不能先插入一条“既要引用券、又还没被券引用”的订单。
--
-- 正确写法（三步，同一事务）：
--   1) INSERT orders (..., coupon_id = NULL)            -- 先不引用券
--   2) INSERT user_coupon (..., order_id = 新订单 id)    -- 券指向已存在的订单
--   3) UPDATE orders SET coupon_id = 新券 id WHERE id = 新订单 id;
--
-- seed.sql 已经按这个顺序写：订单先以 coupon_id = NULL 插入，
-- 用户券插入后再回填 orders.coupon_id。
--
-- 删除同样麻烦：不能先删券（订单还引用着），也不能先删订单
-- （券还引用着）。reset.sql 的做法是先把两侧的可空引用置 NULL，
-- 再按依赖倒序删除。若不想逐个处理，只能在 reset 期间临时
-- SET FOREIGN_KEY_CHECKS = 0（会同时放过所有错误，不推荐当日常习惯）。
--
-- 这也是很多团队最终不建物理外键的原因之一：
-- 跨聚合的循环引用会让“删除/归档/分库分表”都变得别扭。
-- ============================================================

-- ============================================================
-- 7. 验证（只读）
-- ============================================================

-- 7.1 外键总数：预期 34
SELECT COUNT(*) AS fk_count
FROM information_schema.REFERENTIAL_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA = 'ledgerflow';

-- 7.2 逐个列出
SELECT TABLE_NAME, CONSTRAINT_NAME, REFERENCED_TABLE_NAME
FROM information_schema.KEY_COLUMN_USAGE
WHERE TABLE_SCHEMA = 'ledgerflow'
  AND REFERENCED_TABLE_NAME IS NOT NULL
ORDER BY TABLE_NAME, CONSTRAINT_NAME;

-- 7.3 外键自动/显式要求的索引（子表侧）
SELECT TABLE_NAME, INDEX_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS cols
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = 'ledgerflow'
  AND TABLE_NAME IN ('cart_item', 'orders', 'payment_order', 'refund_order',
                     'product_review', 'after_sale_order')
GROUP BY TABLE_NAME, INDEX_NAME
ORDER BY TABLE_NAME, INDEX_NAME;

-- 7.4 逐条单独执行，观察数据库如何拦截（整文件执行会在这里中断，
--     所以默认注释；一次取消一条注释再执行即可）：
--
-- INSERT INTO cart_item (user_id, sku_id, quantity)
-- VALUES (999999, 1, 1);
--   ERROR 1452: Cannot add or update a child row: a foreign key constraint fails
--
-- DELETE FROM users WHERE id = 1;
--   ERROR 1451: Cannot delete or update a parent row: a foreign key constraint fails
--
-- UPDATE orders SET coupon_id = 999999 WHERE id = 1;
--   ERROR 1452（把订单指向不存在的券）
--
-- UPDATE orders SET order_no = 'LF-CHANGED' WHERE id = 1;
--   ERROR 1451（支付单/退款单/明细还引用着它；业务号本就不该改）

-- ============================================================
-- 8. 移除外键（默认注释；确认要恢复“无物理外键”的默认结构时执行）
--
-- 先删约束，再决定是否删除第 0 节加的索引。
-- 约束名必须与第 1~5 节完全一致。
-- ============================================================

-- ALTER TABLE after_sale_log    DROP FOREIGN KEY fk_aftersale_log;
-- ALTER TABLE after_sale_order  DROP FOREIGN KEY fk_aftersale_refund;
-- ALTER TABLE after_sale_order  DROP FOREIGN KEY fk_aftersale_user;
-- ALTER TABLE after_sale_order  DROP FOREIGN KEY fk_aftersale_item;
-- ALTER TABLE after_sale_order  DROP FOREIGN KEY fk_aftersale_order;
-- ALTER TABLE product_review    DROP FOREIGN KEY fk_review_sku;
-- ALTER TABLE product_review    DROP FOREIGN KEY fk_review_spu;
-- ALTER TABLE product_review    DROP FOREIGN KEY fk_review_user;
-- ALTER TABLE product_review    DROP FOREIGN KEY fk_review_order;
-- ALTER TABLE product_review    DROP FOREIGN KEY fk_review_item;
-- ALTER TABLE user_coupon       DROP FOREIGN KEY fk_user_coupon_order;
-- ALTER TABLE user_coupon       DROP FOREIGN KEY fk_user_coupon_template;
-- ALTER TABLE user_coupon       DROP FOREIGN KEY fk_user_coupon_user;
-- ALTER TABLE refund_order      DROP FOREIGN KEY fk_refund_user;
-- ALTER TABLE refund_order      DROP FOREIGN KEY fk_refund_order_no;
-- ALTER TABLE refund_order      DROP FOREIGN KEY fk_refund_payment;
-- ALTER TABLE payment_callback_log DROP FOREIGN KEY fk_callback_payment;
-- ALTER TABLE payment_order     DROP FOREIGN KEY fk_payment_user;
-- ALTER TABLE payment_order     DROP FOREIGN KEY fk_payment_order_no;
-- ALTER TABLE order_delivery    DROP FOREIGN KEY fk_delivery_order;
-- ALTER TABLE order_status_log  DROP FOREIGN KEY fk_statuslog_order;
-- ALTER TABLE order_item        DROP FOREIGN KEY fk_item_sku;
-- ALTER TABLE order_item        DROP FOREIGN KEY fk_item_spu;
-- ALTER TABLE order_item        DROP FOREIGN KEY fk_item_order;
-- ALTER TABLE orders            DROP FOREIGN KEY fk_order_coupon;
-- ALTER TABLE orders            DROP FOREIGN KEY fk_order_user;
-- ALTER TABLE cart_item         DROP FOREIGN KEY fk_cart_sku;
-- ALTER TABLE cart_item         DROP FOREIGN KEY fk_cart_user;
-- ALTER TABLE inventory_log     DROP FOREIGN KEY fk_invlog_sku;
-- ALTER TABLE inventory         DROP FOREIGN KEY fk_inventory_sku;
-- ALTER TABLE product_image     DROP FOREIGN KEY fk_image_spu;
-- ALTER TABLE product_sku       DROP FOREIGN KEY fk_sku_spu;
-- ALTER TABLE product_spu       DROP FOREIGN KEY fk_spu_category;
-- ALTER TABLE user_address      DROP FOREIGN KEY fk_address_user;

-- 可选：连同第 0 节的索引一起删掉
-- ALTER TABLE after_sale_order  DROP INDEX idx_after_sale_refund;
-- ALTER TABLE after_sale_order  DROP INDEX idx_after_sale_item;
-- ALTER TABLE product_review    DROP INDEX idx_review_spu;
-- ALTER TABLE product_review    DROP INDEX idx_review_order;
-- ALTER TABLE refund_order      DROP INDEX idx_refund_user;
-- ALTER TABLE payment_order     DROP INDEX idx_payment_user;
-- ALTER TABLE orders            DROP INDEX idx_orders_coupon;
-- ALTER TABLE cart_item         DROP INDEX idx_cart_sku;
