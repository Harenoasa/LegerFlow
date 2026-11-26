package com.ledgerflow.payment.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import lombok.Data;

import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * 退款单表 refund_order。
 *
 * <p>支持部分退款；累计退款金额需要在支付单行锁下校验。
 */
@Data
@TableName("refund_order")
public class RefundOrderEntity {

    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    private String refundNo;

    private String paymentNo;

    private String orderNo;

    private Long userId;

    private String channel;

    private BigDecimal amount;

    private String reason;

    /** 0=已申请，1=处理中，2=成功，3=拒绝，4=失败。 */
    private Integer status;

    private String channelRefundNo;

    private LocalDateTime appliedAt;

    private LocalDateTime successAt;

    private LocalDateTime createdAt;

    private LocalDateTime updatedAt;
}
