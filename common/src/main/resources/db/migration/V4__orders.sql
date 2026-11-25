-- ============================================================
-- V4：订单域（订单、明细、状态日志、物流）
-- 设计要点：
--   1. orders 保存收货地址快照，user_address 后续修改不影响历史订单。
--   2. order_item 保存商品名称/规格/图片/单价快照，商品改价改名不影响历史订单。
--   3. order_status 用条件 UPDATE 推进（WHERE order_status = 期望值），
--      并用 order_status_log 留痕，防止并发重复流转。
--   4. 物流信息放 order_delivery，支持拆包/多包裹；订单主表不冗余快递单号。
--   5. (user_id, created_at DESC, id DESC) 支持“我的订单”游标分页；
--      (order_status, expire_at) 支持超时关单扫描。
-- ============================================================

CREATE TABLE orders (
    id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    order_no          VARCHAR(32)     NOT NULL COMMENT '订单业务编号',
    user_id           BIGINT UNSIGNED NOT NULL COMMENT '用户 ID（逻辑外键 users.id）',
    order_status      TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '订单状态：0=待支付，10=已支付，20=已发货，30=已完成，40=已取消，50=售后中，60=已退款',
    total_amount      DECIMAL(18, 2)  NOT NULL DEFAULT 0.00 COMMENT '商品总额',
    discount_amount   DECIMAL(18, 2)  NOT NULL DEFAULT 0.00 COMMENT '优惠总额',
    freight_amount    DECIMAL(18, 2)  NOT NULL DEFAULT 0.00 COMMENT '运费',
    pay_amount        DECIMAL(18, 2)  NOT NULL DEFAULT 0.00 COMMENT '应付/实付金额 = total_amount - discount_amount + freight_amount',
    coupon_id         BIGINT UNSIGNED NULL COMMENT '使用的 user_coupon.id（逻辑外键）',
    receiver_name     VARCHAR(64)     NOT NULL COMMENT '收货人快照',
    receiver_phone    VARCHAR(20)     NOT NULL COMMENT '收货电话快照',
    receiver_province VARCHAR(64)     NOT NULL COMMENT '省快照',
    receiver_city     VARCHAR(64)     NOT NULL COMMENT '市快照',
    receiver_district VARCHAR(64)     NOT NULL COMMENT '区/县快照',
    receiver_detail   VARCHAR(255)    NOT NULL COMMENT '详细地址快照',
    buyer_remark      VARCHAR(255)    NOT NULL DEFAULT '' COMMENT '买家备注',
    expire_at         DATETIME(3)     NOT NULL COMMENT '支付超时时间',
    pay_time          DATETIME(3)     NULL COMMENT '支付时间',
    ship_time         DATETIME(3)     NULL COMMENT '发货时间',
    complete_time     DATETIME(3)     NULL COMMENT '完成时间',
    cancel_time       DATETIME(3)     NULL COMMENT '取消时间',
    cancel_reason     VARCHAR(255)    NULL COMMENT '取消原因',
    version           INT             NOT NULL DEFAULT 0 COMMENT '乐观锁版本号',
    created_at        DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    updated_at        DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_order_no (order_no),
    KEY idx_user_created (user_id, created_at DESC, id DESC),
    KEY idx_status_expire (order_status, expire_at),
    KEY idx_created_at (created_at),
    CONSTRAINT chk_orders_amount CHECK (total_amount >= 0 AND discount_amount >= 0 AND freight_amount >= 0 AND pay_amount >= 0)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='订单主表';

CREATE TABLE order_item (
    id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    order_id        BIGINT UNSIGNED NOT NULL COMMENT '订单 ID（逻辑外键 orders.id）',
    spu_id          BIGINT UNSIGNED NOT NULL COMMENT 'SPU ID 快照（逻辑外键 product_spu.id）',
    sku_id          BIGINT UNSIGNED NOT NULL COMMENT 'SKU ID 快照（逻辑外键 product_sku.id）',
    product_name    VARCHAR(200)    NOT NULL COMMENT '下单时商品名称快照',
    sku_spec        VARCHAR(128)    NOT NULL DEFAULT '' COMMENT '下单时规格快照',
    image_url       VARCHAR(512)    NOT NULL DEFAULT '' COMMENT '下单时图片快照',
    unit_price      DECIMAL(18, 2)  NOT NULL COMMENT '下单时单价快照',
    quantity        INT             NOT NULL COMMENT '购买数量',
    item_amount     DECIMAL(18, 2)  NOT NULL COMMENT '商品行小计 = unit_price * quantity',
    discount_amount DECIMAL(18, 2)  NOT NULL DEFAULT 0.00 COMMENT '该行分摊的优惠金额',
    pay_amount      DECIMAL(18, 2)  NOT NULL COMMENT '该行实付金额 = item_amount - discount_amount',
    created_at      DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    PRIMARY KEY (id),
    KEY idx_order_id (order_id),
    KEY idx_sku_id (sku_id),
    KEY idx_spu_id (spu_id),
    CONSTRAINT chk_order_item_quantity CHECK (quantity > 0),
    CONSTRAINT chk_order_item_amount CHECK (unit_price >= 0 AND item_amount >= 0 AND discount_amount >= 0 AND pay_amount >= 0),
    CONSTRAINT chk_order_item_calc CHECK (item_amount = unit_price * quantity AND pay_amount = item_amount - discount_amount)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='订单明细表（商品快照，只增不改）';

CREATE TABLE order_status_log (
    id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    order_id      BIGINT UNSIGNED NOT NULL COMMENT '订单 ID（逻辑外键 orders.id）',
    from_status   TINYINT UNSIGNED NULL COMMENT '原状态，创建订单时为 NULL',
    to_status     TINYINT UNSIGNED NOT NULL COMMENT '新状态',
    operator_type TINYINT UNSIGNED NOT NULL COMMENT '操作者类型：1=用户，2=管理员，3=系统',
    operator_id   BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '操作者 ID，系统操作为 0',
    reason        VARCHAR(255)    NOT NULL DEFAULT '' COMMENT '流转原因',
    created_at    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    PRIMARY KEY (id),
    KEY idx_order_id (order_id, id)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='订单状态流转日志';

CREATE TABLE order_delivery (
    id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    order_id     BIGINT UNSIGNED NOT NULL COMMENT '订单 ID（逻辑外键 orders.id）',
    delivery_no  VARCHAR(32)     NOT NULL COMMENT '包裹/发货单号',
    carrier_code VARCHAR(32)     NOT NULL COMMENT '承运商编码，如 SF/YTO',
    carrier_name VARCHAR(64)     NOT NULL COMMENT '承运商名称',
    tracking_no  VARCHAR(64)     NOT NULL COMMENT '快递单号',
    status       TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '状态：0=待发货，1=已发货，2=运输中，3=已签收',
    shipped_at   DATETIME(3)     NULL COMMENT '发货时间',
    delivered_at DATETIME(3)     NULL COMMENT '签收时间',
    created_at   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    updated_at   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_delivery_no (delivery_no),
    KEY idx_order_id (order_id),
    KEY idx_tracking_no (tracking_no)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='订单物流表（支持拆包裹）';
