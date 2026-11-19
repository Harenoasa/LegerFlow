package com.harenoasa.ledgerflow.payment.dto;

import com.harenoasa.ledgerflow.payment.common.PaymentStatus;
import com.harenoasa.ledgerflow.payment.entity.PaymentOrderEntity;

import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * 支付单查询/创建响应。
 *
 * @param payUrl 收银台地址；查询非待支付单时为空
 */
public record PaymentResponse(String paymentNo,
                              String orderNo,
                              String channel,
                              BigDecimal amount,
                              String status,
                              LocalDateTime expireAt,
                              LocalDateTime paidAt,
                              String payUrl) {

    public static PaymentResponse from(PaymentOrderEntity payment, String payUrl) {
        return new PaymentResponse(
                payment.getPaymentNo(),
                payment.getOrderNo(),
                payment.getChannel(),
                payment.getAmount(),
                PaymentStatus.labelOf(payment.getStatus()),
                payment.getExpireAt(),
                payment.getPaidAt(),
                payUrl);
    }
}
