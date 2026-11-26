package com.ledgerflow.inventory.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import lombok.Data;

/**
 * SKU 库存表 inventory，sku_id 同时是主键。
 */
@Data
@TableName("inventory")
public class InventoryEntity {

    @TableId(value = "sku_id", type = IdType.INPUT)
    private Long skuId;

    private Integer availableStock;

    private Integer lockedStock;

    private Integer version;
}
