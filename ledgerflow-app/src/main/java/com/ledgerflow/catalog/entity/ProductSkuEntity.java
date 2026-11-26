package com.ledgerflow.catalog.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import lombok.Data;

import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * 商品 SKU 表 product_sku。
 */
@Data
@TableName("product_sku")
public class ProductSkuEntity {

    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    private Long spuId;

    private String specSummary;

    private BigDecimal price;

    private Integer status;

    private LocalDateTime deletedAt;
}
