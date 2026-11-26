package com.ledgerflow.inventory.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import lombok.Data;

import java.time.LocalDateTime;

/**
 * 库存变动流水表 inventory_log。
 */
@Data
@TableName("inventory_log")
public class InventoryLogEntity {

    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    private Long skuId;

    private Integer changeType;

    private Integer changeQty;

    private Integer beforeAvailable;

    private Integer afterAvailable;

    private String bizType;

    private String bizNo;

    private String remark;

    private LocalDateTime createdAt;
}
