package com.ledgerflow.catalog.dto;

import java.math.BigDecimal;

/**
 * 商品列表卡片：按 SPU 聚合 SKU 的价格与库存，不包含商品详情。
 */
public record ProductSummaryDTO(
        long id,
        String spuNo,
        String title,
        String subtitle,
        String brand,
        long categoryId,
        String categoryName,
        String mainImage,
        BigDecimal minPrice,
        BigDecimal maxPrice,
        BigDecimal originalPrice,
        int availableStock,
        int soldStock,
        long defaultSkuId,
        String defaultSkuSpec,
        BigDecimal defaultSkuPrice,
        int defaultSkuStock) {
}
