package com.ledgerflow.catalog.service;

import com.ledgerflow.catalog.dto.ProductSummaryDTO;
import jakarta.annotation.Resource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

import java.util.List;

/**
 * 商品列表查询：只读，按 SPU 聚合 SKU 的价格与库存。
 */
@Service
public class ProductQueryService {

    private static final int MAX_LIMIT = 100;

    private static final String LIST_SQL = """
            WITH sku_ranked AS (
                SELECT k.id, k.spu_id, k.spec_summary, k.price, k.original_price,
                       COALESCE(inv.available_stock, 0) AS available_stock,
                       COALESCE(inv.sold_stock, 0) AS sold_stock,
                       ROW_NUMBER() OVER (
                           PARTITION BY k.spu_id
                           ORDER BY (COALESCE(inv.available_stock, 0) = 0), k.price, k.id
                       ) AS rn
                FROM product_sku k
                LEFT JOIN inventory inv ON inv.sku_id = k.id
                WHERE k.status = 1 AND k.deleted_at IS NULL
            ),
            sku_agg AS (
                SELECT spu_id,
                       MIN(price) AS min_price,
                       MAX(price) AS max_price,
                       MIN(NULLIF(original_price, 0)) AS original_price,
                       SUM(available_stock) AS available_stock,
                       SUM(sold_stock) AS sold_stock
                FROM sku_ranked
                GROUP BY spu_id
            )
            SELECT s.id, s.spu_no, s.title, s.subtitle, s.brand,
                   s.category_id, c.name AS category_name,
                   COALESCE(
                       (SELECT i.url FROM product_image i
                        WHERE i.spu_id = s.id
                        ORDER BY i.is_main DESC, i.sort ASC, i.id ASC
                        LIMIT 1),
                       s.main_image_url) AS main_image,
                   a.min_price, a.max_price, a.original_price,
                   a.available_stock, a.sold_stock,
                   r.id AS default_sku_id, r.spec_summary AS default_sku_spec,
                   r.price AS default_sku_price, r.available_stock AS default_sku_stock
            FROM product_spu s
            JOIN category c ON c.id = s.category_id
            JOIN sku_agg a ON a.spu_id = s.id
            JOIN sku_ranked r ON r.spu_id = s.id AND r.rn = 1
            WHERE s.status = 1 AND s.deleted_at IS NULL
            ORDER BY s.id DESC
            LIMIT ?
            """;

    @Resource
    private JdbcTemplate jdbcTemplate;

    public List<ProductSummaryDTO> listProducts(int limit) {
        int safeLimit = Math.max(1, Math.min(limit, MAX_LIMIT));
        return jdbcTemplate.query(LIST_SQL, (rs, rowNum) -> new ProductSummaryDTO(
                rs.getLong("id"),
                rs.getString("spu_no"),
                rs.getString("title"),
                rs.getString("subtitle"),
                rs.getString("brand"),
                rs.getLong("category_id"),
                rs.getString("category_name"),
                rs.getString("main_image"),
                rs.getBigDecimal("min_price"),
                rs.getBigDecimal("max_price"),
                rs.getBigDecimal("original_price"),
                rs.getInt("available_stock"),
                rs.getInt("sold_stock"),
                rs.getLong("default_sku_id"),
                rs.getString("default_sku_spec"),
                rs.getBigDecimal("default_sku_price"),
                rs.getInt("default_sku_stock")), safeLimit);
    }
}
