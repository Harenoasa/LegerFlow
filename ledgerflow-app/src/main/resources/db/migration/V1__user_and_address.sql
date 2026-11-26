-- ============================================================
-- V1：用户域（用户、收货地址）
-- 设计要点：
--   1. 软删除用 deleted_at，配合 STORED 生成列 + 唯一索引，
--      既保留历史数据，又允许手机号/邮箱在删除后被复用。
--   2. default_owner 生成列保证“每个用户最多一个默认地址”，
--      不依赖应用层先查后改（并发下会失效）。
-- ============================================================

CREATE TABLE users (
    id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    user_no       VARCHAR(32)     NOT NULL COMMENT '用户业务编号',
    username      VARCHAR(64)     NOT NULL COMMENT '登录名',
    phone         VARCHAR(20)     NOT NULL COMMENT '手机号',
    email         VARCHAR(128)    NULL COMMENT '邮箱',
    password_hash VARCHAR(100)    NOT NULL COMMENT '密码哈希（BCrypt），禁止存明文',
    nickname      VARCHAR(64)     NOT NULL DEFAULT '' COMMENT '昵称',
    status        TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT '状态：0=禁用，1=正常',
    member_level  TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '会员等级：0=普通，1=白银，2=黄金',
    deleted_at    DATETIME(3)     NULL COMMENT '软删除时间，NULL 表示未删除',
    created_at    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    updated_at    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
    active_phone  VARCHAR(20)     GENERATED ALWAYS AS (IF(deleted_at IS NULL, phone, NULL)) STORED COMMENT '未删除用户的手机号，用于唯一约束',
    active_email  VARCHAR(128)    GENERATED ALWAYS AS (IF(deleted_at IS NULL, email, NULL)) STORED COMMENT '未删除用户的邮箱，用于唯一约束',
    PRIMARY KEY (id),
    UNIQUE KEY uk_user_no (user_no),
    UNIQUE KEY uk_username (username),
    UNIQUE KEY uk_active_phone (active_phone),
    UNIQUE KEY uk_active_email (active_email),
    KEY idx_created_at (created_at)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='用户表';

CREATE TABLE user_address (
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    user_id        BIGINT UNSIGNED NOT NULL COMMENT '用户 ID（逻辑外键 users.id）',
    receiver_name  VARCHAR(64)     NOT NULL COMMENT '收件人姓名',
    receiver_phone VARCHAR(20)     NOT NULL COMMENT '收件人电话',
    province       VARCHAR(64)     NOT NULL COMMENT '省',
    city           VARCHAR(64)     NOT NULL COMMENT '市',
    district       VARCHAR(64)     NOT NULL COMMENT '区/县',
    detail_address VARCHAR(255)    NOT NULL COMMENT '详细地址',
    postal_code    VARCHAR(16)     NULL COMMENT '邮编',
    is_default     TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否默认地址：0=否，1=是',
    deleted_at     DATETIME(3)     NULL COMMENT '软删除时间，NULL 表示未删除',
    created_at     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    updated_at     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
    default_owner  BIGINT UNSIGNED GENERATED ALWAYS AS (IF(is_default = 1 AND deleted_at IS NULL, user_id, NULL)) STORED COMMENT '默认地址唯一约束载体：非默认地址或已删除地址为 NULL',
    PRIMARY KEY (id),
    KEY idx_user_id (user_id),
    UNIQUE KEY uk_default_owner (default_owner),
    CONSTRAINT chk_user_address_default CHECK (is_default IN (0, 1))
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='用户收货地址表';
