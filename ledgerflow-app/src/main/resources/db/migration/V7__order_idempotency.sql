-- ============================================================
-- V7：订单创建幂等
-- 设计要点：
--   1. client_token 由客户端生成，一次下单意图一个 token；
--      同一 token 的重复提交/重试返回同一订单，不重复扣库存、用券。
--   2. request_hash 是规范化请求体的 SHA-256，用于识别
--      “同一个 token 对应了不同下单内容”的冲突。
--   3. 唯一键 (user_id, client_token) 是并发下的最终闸门；
--      不能只靠应用层“先查后插”。
--   4. 两列允许 NULL，兼容已有订单；新订单由应用层保证非空。
--   5. token / hash 使用 ascii_bin，避免默认的 ai_ci 大小写不敏感
--      导致 ABC 与 abc 被视为同一个幂等键。
-- ============================================================

ALTER TABLE orders
    ADD COLUMN client_token VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin
        NULL COMMENT '客户端幂等键，同一 token 代表同一次下单意图' AFTER user_id,
    ADD COLUMN request_hash CHAR(64) CHARACTER SET ascii COLLATE ascii_bin
        NULL COMMENT '规范化请求体的 SHA-256，用于识别幂等键复用冲突' AFTER client_token,
    ADD UNIQUE KEY uk_user_client_token (user_id, client_token);
