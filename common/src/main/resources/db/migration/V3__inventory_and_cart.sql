-- ============================================================
-- V3：库存与购物车
-- 设计要点：
--   1. inventory 一个 SKU 一行，是典型“热点行”。扣减必须用
--      条件 UPDATE（available_stock >= n）或乐观锁，不能先查后改。
--   2. inventory_log 用唯一键 (biz_type, biz_no, sku_id, change_type)
--      做业务幂等，重复消息不会重复扣减/回补库存。
--   3. 购物车不保存价格，结算时重新读取 SKU 当前价格与库存。
-- ============================================================

CREATE TABLE inventory (
    sku_id          BIGINT UNSIGNED NOT NULL COMMENT 'SKU ID，同时作为主键（一 SKU 一行）',
    available_stock INT             NOT NULL DEFAULT 0 COMMENT '可售库存',
    locked_stock    INT             NOT NULL DEFAULT 0 COMMENT '锁定库存（已下单未支付/未发货）',
    sold_stock      INT             NOT NULL DEFAULT 0 COMMENT '已售库存',
    version         INT             NOT NULL DEFAULT 0 COMMENT '乐观锁版本号',
    created_at      DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    updated_at      DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
    PRIMARY KEY (sku_id),
    CONSTRAINT chk_inventory_available CHECK (available_stock >= 0),
    CONSTRAINT chk_inventory_locked CHECK (locked_stock >= 0),
    CONSTRAINT chk_inventory_sold CHECK (sold_stock >= 0)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='SKU 库存表（热点行）';

CREATE TABLE inventory_log (
    id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    sku_id           BIGINT UNSIGNED NOT NULL COMMENT 'SKU ID（逻辑外键 product_sku.id）',
    change_type      TINYINT UNSIGNED NOT NULL COMMENT '变动类型：1=锁定，2=解锁，3=扣减，4=回补，5=调整',
    change_qty       INT             NOT NULL COMMENT '本次变动数量（正数）',
    before_available INT             NOT NULL COMMENT '变动前可售库存',
    after_available  INT             NOT NULL COMMENT '变动后可售库存',
    biz_type         VARCHAR(32)     NOT NULL COMMENT '业务类型：ORDER_CREATE/ORDER_PAY/ORDER_CANCEL/REFUND',
    biz_no           VARCHAR(64)     NOT NULL COMMENT '业务单号，用于幂等',
    remark           VARCHAR(255)    NOT NULL DEFAULT '' COMMENT '备注',
    created_at       DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_biz (biz_type, biz_no, sku_id, change_type),
    KEY idx_sku_created (sku_id, created_at),
    CONSTRAINT chk_inventory_log_qty CHECK (change_qty > 0)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='库存变动流水表（业务幂等）';

CREATE TABLE cart_item (
    id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    user_id    BIGINT UNSIGNED NOT NULL COMMENT '用户 ID（逻辑外键 users.id）',
    sku_id     BIGINT UNSIGNED NOT NULL COMMENT 'SKU ID（逻辑外键 product_sku.id）',
    quantity   INT             NOT NULL DEFAULT 1 COMMENT '数量',
    selected   TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT '是否勾选：0=否，1=是',
    created_at DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    updated_at DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_user_sku (user_id, sku_id),
    KEY idx_user_updated (user_id, updated_at),
    CONSTRAINT chk_cart_quantity CHECK (quantity > 0),
    CONSTRAINT chk_cart_selected CHECK (selected IN (0, 1))
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='购物车表（不存价格）';
