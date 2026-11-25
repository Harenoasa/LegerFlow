-- ============================================================
-- V8：支付幂等、订单结算唯一、消费去重
-- 设计依据：docs/payment-and-mq-design.md 第 4 节
--   1. payment_order 增加支付创建幂等键：
--      同一订单 + 同一客户端 token 只创建一笔支付尝试。
--   2. orders.paid_payment_no 记录“真正结算该订单”的支付单。
--      第二笔成功支付仍记 payment_order.status=1（钱确实到账），
--      但不挂到订单上，走退款；唯一索引保证一个订单只结算一笔。
--      MySQL 唯一索引允许多个 NULL，未支付订单不受影响。
--   3. (order_no, status) 支撑创建支付时查同订单待支付单。
--   4. processed_event 供 Kafka 消费端做通用去重；
--      业务唯一键仍然是最后防线。
-- ============================================================

ALTER TABLE payment_order
    ADD COLUMN client_token VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin
        NULL COMMENT '客户端支付意图幂等键' AFTER order_no,
    ADD UNIQUE KEY uk_order_client_token (order_no, client_token);

ALTER TABLE orders
    ADD COLUMN paid_payment_no VARCHAR(32)
        NULL COMMENT '成功结算该订单的支付单号' AFTER pay_time,
    ADD UNIQUE KEY uk_paid_payment_no (paid_payment_no);

ALTER TABLE payment_order
    ADD KEY idx_order_status (order_no, status);

CREATE TABLE processed_event (
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    consumer_group VARCHAR(64)     NOT NULL COMMENT '消费组',
    event_id       VARCHAR(64)     NOT NULL COMMENT '事件 ID（outbox_event.event_id）',
    event_type     VARCHAR(64)     NOT NULL COMMENT '事件类型',
    processed_at   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '处理时间（UTC）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_consumer_event (consumer_group, event_id),
    KEY idx_processed_at (processed_at)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='Kafka 消费幂等去重表';
