package com.ledgerflow.payment.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import lombok.Data;

import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * 支付单表 payment_order。
 *
 * <p>一个订单允许多次支付尝试，所以 order_no 不唯一，payment_no 唯一。
 */
@Data
@TableName("payment_order")
public class PaymentOrderEntity {

    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    private String paymentNo;

    private String orderNo;

    /** V8 新增的支付创建幂等键，同一订单 + token 只创建一笔。 */
    private String clientToken;

    private Long userId;

    /** ALIPAY / WECHAT / BALANCE / MOCK。 */
    private String channel;

    private BigDecimal amount;

    /** 见 {@link com.ledgerflow.common.PaymentStatus}。 */
    private Integer status;

    private String externalTradeNo;

    private LocalDateTime expireAt;

    private LocalDateTime paidAt;

    private LocalDateTime closedAt;

    private LocalDateTime createdAt;

    private LocalDateTime updatedAt;
}
