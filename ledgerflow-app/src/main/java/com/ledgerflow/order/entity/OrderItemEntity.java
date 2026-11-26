package com.ledgerflow.order.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import lombok.Data;

import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * 订单明细表 order_item。
 */
@Data
@TableName("order_item")
public class OrderItemEntity {

    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    private Long orderId;

    private Long spuId;

    private Long skuId;

    private String productName;

    private String skuSpec;

    private String imageUrl;

    private BigDecimal unitPrice;

    private Integer quantity;

    private BigDecimal itemAmount;

    private BigDecimal discountAmount;

    private BigDecimal payAmount;

    private LocalDateTime createdAt;
}
