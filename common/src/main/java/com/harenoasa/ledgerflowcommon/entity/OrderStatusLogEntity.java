package com.harenoasa.ledgerflowcommon.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import lombok.Data;

import java.time.LocalDateTime;

/**
 * 订单状态流转日志表 order_status_log。
 */
@Data
@TableName("order_status_log")
public class OrderStatusLogEntity {

    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    private Long orderId;

    private Integer fromStatus;

    private Integer toStatus;

    private Integer operatorType;

    private Long operatorId;

    private String reason;

    private LocalDateTime createdAt;
}
