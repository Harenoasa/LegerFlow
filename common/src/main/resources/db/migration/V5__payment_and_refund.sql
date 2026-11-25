-- ============================================================
-- V5：支付与退款
-- 设计要点：
--   1. 一个订单允许多次支付尝试（换渠道、重新发起），
--      所以 payment_order.order_no 不唯一；payment_no 唯一。
--   2. (channel, external_trade_no) 唯一 + 回调日志
--      (channel, notify_id) 唯一，双保险实现支付回调幂等。
--   3. refund_order 支持多次部分退款；累计退款金额由应用层
--      加锁/条件更新校验，对账 SQL 兜底。
-- ============================================================

CREATE TABLE payment_order (
    id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    payment_no        VARCHAR(32)     NOT NULL COMMENT '支付单号',
    order_no          VARCHAR(32)     NOT NULL COMMENT '关联订单业务编号（逻辑外键 orders.order_no）',
    user_id           BIGINT UNSIGNED NOT NULL COMMENT '用户 ID（逻辑外键 users.id）',
    channel           VARCHAR(32)     NOT NULL COMMENT '支付渠道：ALIPAY/WECHAT/BALANCE',
    amount            DECIMAL(18, 2)  NOT NULL COMMENT '支付金额',
    status            TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '状态：0=待支付，1=成功，2=失败，3=已关闭',
    external_trade_no VARCHAR(64)     NULL COMMENT '渠道交易号，成功后写入',
    expire_at         DATETIME(3)     NOT NULL COMMENT '支付超时时间',
    paid_at           DATETIME(3)     NULL COMMENT '支付成功时间',
    closed_at         DATETIME(3)     NULL COMMENT '关闭时间',
    created_at        DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    updated_at        DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_payment_no (payment_no),
    UNIQUE KEY uk_channel_trade (channel, external_trade_no),
    KEY idx_order_no (order_no),
    KEY idx_status_expire (status, expire_at),
    CONSTRAINT chk_payment_amount CHECK (amount >= 0)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='支付单表（一订单可多次支付尝试）';

CREATE TABLE payment_callback_log (
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    notify_id      VARCHAR(64)     NOT NULL COMMENT '渠道通知 ID，用于幂等',
    payment_no     VARCHAR(32)     NOT NULL COMMENT '支付单号（逻辑外键 payment_order.payment_no）',
    channel        VARCHAR(32)     NOT NULL COMMENT '支付渠道',
    raw_body       MEDIUMTEXT      NOT NULL COMMENT '原始回调报文（排查/重放用）',
    process_status TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '处理状态：0=已接收，1=处理成功，2=处理失败',
    error_msg      VARCHAR(512)    NULL COMMENT '失败原因',
    processed_at   DATETIME(3)     NULL COMMENT '处理完成时间',
    created_at     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_channel_notify (channel, notify_id),
    KEY idx_payment_no (payment_no)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='支付回调日志（幂等闸门）';

CREATE TABLE refund_order (
    id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    refund_no         VARCHAR(32)     NOT NULL COMMENT '退款单号',
    payment_no        VARCHAR(32)     NOT NULL COMMENT '原支付单号（逻辑外键 payment_order.payment_no）',
    order_no          VARCHAR(32)     NOT NULL COMMENT '关联订单号（逻辑外键 orders.order_no）',
    user_id           BIGINT UNSIGNED NOT NULL COMMENT '用户 ID（逻辑外键 users.id）',
    channel           VARCHAR(32)     NOT NULL COMMENT '退款渠道，与原支付一致',
    amount            DECIMAL(18, 2)  NOT NULL COMMENT '本次退款金额（支持部分退款）',
    reason            VARCHAR(255)    NOT NULL DEFAULT '' COMMENT '退款原因',
    status            TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '状态：0=已申请，1=处理中，2=成功，3=拒绝，4=失败',
    channel_refund_no VARCHAR(64)     NULL COMMENT '渠道退款单号',
    applied_at        DATETIME(3)     NOT NULL COMMENT '申请时间',
    success_at        DATETIME(3)     NULL COMMENT '退款成功时间',
    created_at        DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    updated_at        DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_refund_no (refund_no),
    UNIQUE KEY uk_channel_refund (channel, channel_refund_no),
    KEY idx_order_no (order_no),
    KEY idx_payment_no (payment_no),
    KEY idx_status_created (status, created_at),
    CONSTRAINT chk_refund_amount CHECK (amount > 0)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='退款单表（支持部分退款）';
