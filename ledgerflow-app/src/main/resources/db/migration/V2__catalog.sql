-- ============================================================
-- V2：商品域（分类、SPU、SKU、图片）
-- 设计要点：
--   1. 分类与商品分离；SPU 表示“商品”，SKU 表示“可售规格”。
--   2. 价格放在 SKU 上，订单只保存快照，商品改价不影响历史订单。
--   3. spec_json 保存结构化规格，spec_summary 保存展示文案；
--      JSON 列便于扩展，但不适合作为高频查询条件。
--   4. 标题建 ngram 全文索引，支持中文关键词搜索（MySQL 5.7+）。
-- ============================================================

CREATE TABLE category (
    id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    parent_id  BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '父分类 ID，0=一级分类',
    name       VARCHAR(64)     NOT NULL COMMENT '分类名称',
    level      TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT '层级：1=一级，2=二级',
    sort       INT             NOT NULL DEFAULT 0 COMMENT '排序值，越小越靠前',
    path       VARCHAR(255)    NOT NULL DEFAULT '' COMMENT '物化路径，如 /1/11/',
    status     TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT '状态：0=禁用，1=启用',
    created_at DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    updated_at DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_parent_name (parent_id, name),
    KEY idx_parent_sort (parent_id, sort)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='商品分类表';

CREATE TABLE product_spu (
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    spu_no         VARCHAR(32)     NOT NULL COMMENT 'SPU 业务编号',
    category_id    BIGINT UNSIGNED NOT NULL COMMENT '分类 ID（逻辑外键 category.id）',
    title          VARCHAR(200)    NOT NULL COMMENT '商品标题',
    subtitle       VARCHAR(255)    NOT NULL DEFAULT '' COMMENT '副标题/卖点',
    brand          VARCHAR(64)     NOT NULL DEFAULT '' COMMENT '品牌',
    main_image_url VARCHAR(512)    NOT NULL DEFAULT '' COMMENT '主图 URL',
    description    TEXT            NULL COMMENT '商品详情',
    status         TINYINT UNSIGNED NOT NULL DEFAULT 2 COMMENT '状态：0=下架，1=上架，2=草稿',
    deleted_at     DATETIME(3)     NULL COMMENT '软删除时间，NULL 表示未删除',
    created_at     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    updated_at     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_spu_no (spu_no),
    KEY idx_category_status (category_id, status, id),
    FULLTEXT KEY ft_title (title) WITH PARSER ngram
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='商品 SPU 表';

CREATE TABLE product_sku (
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    spu_id         BIGINT UNSIGNED NOT NULL COMMENT 'SPU ID（逻辑外键 product_spu.id）',
    sku_no         VARCHAR(32)     NOT NULL COMMENT 'SKU 业务编号',
    spec_json      JSON            NOT NULL COMMENT '规格 JSON，如 {"颜色":"黑色","容量":"256G"}',
    spec_summary   VARCHAR(128)    NOT NULL DEFAULT '' COMMENT '规格展示文案，如“黑色 / 256G”',
    price          DECIMAL(18, 2)  NOT NULL COMMENT '当前售价',
    original_price DECIMAL(18, 2)  NOT NULL DEFAULT 0.00 COMMENT '划线价',
    status         TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT '状态：0=下架，1=上架',
    deleted_at     DATETIME(3)     NULL COMMENT '软删除时间，NULL 表示未删除',
    created_at     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    updated_at     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_sku_no (sku_no),
    KEY idx_spu_id (spu_id),
    CONSTRAINT chk_sku_price CHECK (price >= 0 AND original_price >= 0)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='商品 SKU 表';

CREATE TABLE product_image (
    id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    spu_id     BIGINT UNSIGNED NOT NULL COMMENT 'SPU ID（逻辑外键 product_spu.id）',
    url        VARCHAR(512)    NOT NULL COMMENT '图片 URL',
    sort       INT             NOT NULL DEFAULT 0 COMMENT '排序值',
    is_main    TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否主图：0=否，1=是',
    created_at DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
    PRIMARY KEY (id),
    KEY idx_spu_sort (spu_id, sort),
    CONSTRAINT chk_product_image_main CHECK (is_main IN (0, 1))
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='商品图片表';
