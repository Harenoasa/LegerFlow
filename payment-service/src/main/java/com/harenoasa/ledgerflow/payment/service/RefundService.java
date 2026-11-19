package com.harenoasa.ledgerflow.payment.service;

import com.harenoasa.ledgerflow.payment.common.PaymentNoGenerator;
import com.harenoasa.ledgerflow.payment.entity.PaymentOrderEntity;
import com.harenoasa.ledgerflow.payment.entity.RefundOrderEntity;
import com.harenoasa.ledgerflow.payment.mapper.RefundOrderMapper;
import com.harenoasa.ledgerflowcommon.common.OrderStatus;
import com.harenoasa.ledgerflowcommon.entity.OrdersEntity;
import jakarta.annotation.Resource;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * 退款单创建。
 *
 * <p>当前只处理“晚到支付/重复支付”自动退款：钱已经到账，但订单已取消或已被另一笔支付结算。
 * 调用方必须已经持有 payment_order 行锁，累计退款金额的上限校验才可靠。
 */
@Service
public class RefundService {

    private static final Logger log = LoggerFactory.getLogger(RefundService.class);

    @Resource
    private RefundOrderMapper refundOrderMapper;

    @Resource
    private PaymentNoGenerator paymentNoGenerator;

    /**
     * 为晚到/重复支付创建退款单。已经全额退款时返回 null。
     */
    @Transactional
    public RefundOrderEntity createLateOrDuplicateRefund(OrdersEntity order,
                                                         PaymentOrderEntity payment,
                                                         LocalDateTime now) {
        BigDecimal reserved = refundOrderMapper.sumReservedAmount(payment.getPaymentNo());
        if (reserved == null) {
            reserved = BigDecimal.ZERO;
        }
        BigDecimal refundable = payment.getAmount().subtract(reserved);
        if (refundable.signum() <= 0) {
            log.warn("支付单已无可退金额，paymentNo={}, amount={}, reserved={}",
                    payment.getPaymentNo(), payment.getAmount(), reserved);
            return null;
        }

        RefundOrderEntity refund = new RefundOrderEntity();
        refund.setRefundNo(paymentNoGenerator.nextRefundNo());
        refund.setPaymentNo(payment.getPaymentNo());
        refund.setOrderNo(payment.getOrderNo());
        refund.setUserId(payment.getUserId());
        refund.setChannel(payment.getChannel());
        refund.setAmount(refundable);
        refund.setReason(refundReason(order));
        refund.setStatus(0);
        refund.setAppliedAt(now);
        refundOrderMapper.insert(refund);

        log.info("创建晚到/重复支付退款，refundNo={}, paymentNo={}, amount={}",
                refund.getRefundNo(), payment.getPaymentNo(), refundable);
        return refund;
    }

    private String refundReason(OrdersEntity order) {
        Integer status = order.getOrderStatus();
        if (Integer.valueOf(OrderStatus.CANCELLED.code()).equals(status)
                || Integer.valueOf(OrderStatus.REFUNDED.code()).equals(status)) {
            return "订单已取消，晚到支付退款";
        }
        return "重复支付退款";
    }
}
