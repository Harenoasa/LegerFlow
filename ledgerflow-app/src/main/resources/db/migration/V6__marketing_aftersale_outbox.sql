-- ============================================================
-- V6：营销、评价、售后、Outbox
-- 设计要点：
--   1. 优惠券模板 issued_count 用条件 UPDATE 防超发：
--        UPDATE coupon_template SET issued_count = issued_count + 1
--        WHERE id = ? AND issued_count < total_count;
--   2. user_coupon 用条件 UPDATE（WHERE status = 0）防并发重复使用。
--   3. product_review.order_item_id 唯一，保证一个订单行只能评价一次。
--   4. after_sale_order 支持部分退款/退货退款/换货，状态日志留痕。
--   5. outbox_event 与业务写在同一事务，后台轮询投递 MQ，
--      实现“本地事务 + 最终一致性”，避免双写不一致。
-- ============================================================

CREATE TABLE coupon_template (
    id                  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    code                VARCHAR(32)     NOT NULL COMMENT '券模板编码',
    name                VARCHAR(128)    NOT NULL COMMENT '券名称',
    coupon_type         TINYINT UNSIGNED NOT NULL COMMENT '类型：1=满减券，2=折扣券',
    discount_amount     DECIMAL(18, 2)  NOT NULL DEFAULT 0.00 COMMENT '满减金额（满减券）',
    discount_rate       DECIMAL(5, 4)   NOT NULL DEFAULT 1.0000 COMMENT '折扣率，0.9000=9 折（折扣券）',
    threshold_amount    DECIMAL(18, 2)  NOT NULL DEFAULT 0.00 COMMENT '使用门槛',
    max_discount_amount DECIMAL(18, 2)  NULL COMMENT '折扣券最高优惠金额',
    valid_from          DATETIME(3)     NOT NULL COMMENT '有效期开始',
    valid_to            DATETIME(3)     NOT NULL COMMENT '有效期结束',
    total_count         INT             NOT NULL COMMENT '发行总量',
    issued_count        INT             NOT NULL DEFAULT 0 COMMENT '已领取数量',
    per_user_limit      INT             NOT NULL DEFAULT 1 COMMENT '每人限领数量',
    status              TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT '状态：0=停用，1=进行中，2=已结束',
    created_at          DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    updated_at          DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_code (code),
    KEY idx_status_valid (status, valid_from, valid_to),
    CONSTRAINT chk_coupon_type CHECK (coupon_type IN (1, 2)),
    CONSTRAINT chk_coupon_rate CHECK (discount_rate > 0 AND discount_rate <= 1),
    CONSTRAINT chk_coupon_count CHECK (total_count >= 0 AND issued_count >= 0 AND issued_count <= total_count),
    CONSTRAINT chk_coupon_amount CHECK (discount_amount >= 0 AND threshold_amount >= 0 AND (max_discount_amount IS NULL OR max_discount_amount >= 0))
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='优惠券模板表';

CREATE TABLE user_coupon (
    id                 BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    user_id            BIGINT UNSIGNED NOT NULL COMMENT '用户 ID（逻辑外键 users.id）',
    coupon_template_id BIGINT UNSIGNED NOT NULL COMMENT '券模板 ID（逻辑外键 coupon_template.id）',
    status             TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '状态：0=未使用，1=已使用，2=已过期',
    received_at        DATETIME(3)     NOT NULL COMMENT '领取时间',
    used_at            DATETIME(3)     NULL COMMENT '使用时间',
    order_id           BIGINT UNSIGNED NULL COMMENT '核销订单 ID（逻辑外键 orders.id）',
    expire_at          DATETIME(3)     NOT NULL COMMENT '过期时间',
    created_at         DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    updated_at         DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
    PRIMARY KEY (id),
    KEY idx_user_status (user_id, status, expire_at),
    KEY idx_template_id (coupon_template_id),
    KEY idx_order_id (order_id),
    CONSTRAINT chk_user_coupon_status CHECK (status IN (0, 1, 2))
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='用户优惠券表';

CREATE TABLE product_review (
    id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    order_item_id BIGINT UNSIGNED NOT NULL COMMENT '订单行 ID（逻辑外键 order_item.id）',
    order_id      BIGINT UNSIGNED NOT NULL COMMENT '订单 ID（逻辑外键 orders.id）',
    user_id       BIGINT UNSIGNED NOT NULL COMMENT '用户 ID（逻辑外键 users.id）',
    spu_id        BIGINT UNSIGNED NOT NULL COMMENT 'SPU ID（逻辑外键 product_spu.id）',
    sku_id        BIGINT UNSIGNED NOT NULL COMMENT 'SKU ID（逻辑外键 product_sku.id）',
    rating        TINYINT UNSIGNED NOT NULL COMMENT '评分 1-5 星',
    content       VARCHAR(1000)   NOT NULL DEFAULT '' COMMENT '评价内容',
    images        JSON            NULL COMMENT '评价图片 URL 数组',
    status        TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT '状态：0=隐藏，1=展示',
    created_at    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_order_item (order_item_id),
    KEY idx_sku_created (sku_id, created_at),
    KEY idx_user_id (user_id),
    CONSTRAINT chk_review_rating CHECK (rating BETWEEN 1 AND 5)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='商品评价表（一个订单行只能评价一次）';

CREATE TABLE after_sale_order (
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    after_sale_no  VARCHAR(32)     NOT NULL COMMENT '售后单号',
    order_id       BIGINT UNSIGNED NOT NULL COMMENT '订单 ID（逻辑外键 orders.id）',
    order_item_id  BIGINT UNSIGNED NOT NULL COMMENT '订单行 ID（逻辑外键 order_item.id）',
    user_id        BIGINT UNSIGNED NOT NULL COMMENT '用户 ID（逻辑外键 users.id）',
    after_sale_type TINYINT UNSIGNED NOT NULL COMMENT '售后类型：1=仅退款，2=退货退款，3=换货',
    reason         VARCHAR(255)    NOT NULL COMMENT '售后原因',
    description    VARCHAR(1000)   NOT NULL DEFAULT '' COMMENT '问题描述',
    amount         DECIMAL(18, 2)  NOT NULL DEFAULT 0.00 COMMENT '申请退款金额',
    status         TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '状态：0=已申请，1=已同意，2=已拒绝，3=退货中，4=已完成，5=已关闭',
    refund_no      VARCHAR(32)     NULL COMMENT '关联退款单号（逻辑外键 refund_order.refund_no）',
    created_at     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    updated_at     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_after_sale_no (after_sale_no),
    KEY idx_order_id (order_id),
    KEY idx_user_status (user_id, status, created_at),
    KEY idx_status_created (status, created_at),
    CONSTRAINT chk_after_sale_type CHECK (after_sale_type IN (1, 2, 3)),
    CONSTRAINT chk_after_sale_amount CHECK (amount >= 0)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='售后单表';

CREATE TABLE after_sale_log (
    id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    after_sale_id BIGINT UNSIGNED NOT NULL COMMENT '售后单 ID（逻辑外键 after_sale_order.id）',
    from_status   TINYINT UNSIGNED NULL COMMENT '原状态，创建时为 NULL',
    to_status     TINYINT UNSIGNED NOT NULL COMMENT '新状态',
    operator_type TINYINT UNSIGNED NOT NULL COMMENT '操作者类型：1=用户，2=商家，3=系统',
    operator_id   BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '操作者 ID',
    remark        VARCHAR(255)    NOT NULL DEFAULT '' COMMENT '备注',
    created_at    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    PRIMARY KEY (id),
    KEY idx_after_sale_id (after_sale_id, id)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='售后状态流转日志';

CREATE TABLE outbox_event (
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    event_id       VARCHAR(64)     NOT NULL COMMENT '事件唯一 ID（幂等）',
    aggregate_type VARCHAR(32)     NOT NULL COMMENT '聚合类型：ORDER/PAYMENT/REFUND',
    aggregate_id   VARCHAR(64)     NOT NULL COMMENT '聚合业务 ID',
    event_type     VARCHAR(64)     NOT NULL COMMENT '事件类型',
    payload        JSON            NOT NULL COMMENT '事件内容',
    status         TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '状态：0=待发布，1=已发布，2=发布失败',
    retry_count    INT             NOT NULL DEFAULT 0 COMMENT '重试次数',
    next_retry_at  DATETIME(3)     NULL COMMENT '下次重试时间',
    published_at   DATETIME(3)     NULL COMMENT '发布时间',
    created_at     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    updated_at     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_event_id (event_id),
    KEY idx_status_next (status, next_retry_at),
    KEY idx_aggregate (aggregate_type, aggregate_id)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='事务性发件箱（最终一致性）';
