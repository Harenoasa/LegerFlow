package com.harenoasa.ledgerflow.payment.service;

import com.baomidou.mybatisplus.core.toolkit.Wrappers;
import com.harenoasa.ledgerflow.payment.common.PaymentNoGenerator;
import com.harenoasa.ledgerflow.payment.common.PaymentStatus;
import com.harenoasa.ledgerflow.payment.entity.PaymentOrderEntity;
import com.harenoasa.ledgerflow.payment.mapper.PaymentOrderMapper;
import com.harenoasa.ledgerflowcommon.common.OrderStatus;
import com.harenoasa.ledgerflowcommon.entity.OrdersEntity;
import com.harenoasa.ledgerflowcommon.mapper.OrdersMapper;
import jakarta.annotation.Resource;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.server.ResponseStatusException;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Objects;

/**
 * 支付单落库。
 *
 * <p>单独拆出来是为了让 {@link PaymentService} 能在数据库事务提交之后再调用渠道预下单，
 * 避免把外部 HTTP 调用包进事务。
 */
@Service
public class PaymentRecordService {

    @Resource
    private OrdersMapper ordersMapper;

    @Resource
    private PaymentOrderMapper paymentOrderMapper;

    @Resource
    private PaymentNoGenerator paymentNoGenerator;

    /**
     * 创建或复用一笔支付尝试。
     *
     * <p>先锁 orders 行，让同一订单的“创建支付”串行化：
     * <ul>
     *   <li>同一 clientToken 已存在：直接复用</li>
     *   <li>同渠道已有待支付单：直接复用</li>
     *   <li>其他渠道有待支付单：先关闭，再创建新的一笔</li>
     * </ul>
     */
    @Transactional
    public PaymentOrderEntity createOrReuse(Long userId, String orderNo, String channel, String clientToken) {
        OrdersEntity order = ordersMapper.selectOne(
                Wrappers.<OrdersEntity>lambdaQuery()
                        .eq(OrdersEntity::getOrderNo, orderNo)
                        .last("FOR UPDATE"));
        if (order == null) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "ORDER_NOT_FOUND");
        }
        if (!Objects.equals(order.getUserId(), userId)) {
            throw new ResponseStatusException(HttpStatus.FORBIDDEN, "ORDER_FORBIDDEN");
        }
        if (!Integer.valueOf(OrderStatus.PENDING_PAYMENT.code()).equals(order.getOrderStatus())) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "ORDER_NOT_PAYABLE");
        }

        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        if (order.getExpireAt() == null || !order.getExpireAt().isAfter(now)) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "ORDER_EXPIRED");
        }
        if (order.getPayAmount() == null || order.getPayAmount().signum() <= 0) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "ORDER_AMOUNT_INVALID");
        }

        if (clientToken != null && !clientToken.isBlank()) {
            PaymentOrderEntity byToken = paymentOrderMapper.selectOne(
                    Wrappers.<PaymentOrderEntity>lambdaQuery()
                            .eq(PaymentOrderEntity::getOrderNo, orderNo)
                            .eq(PaymentOrderEntity::getClientToken, clientToken)
                            .last("LIMIT 1"));
            if (byToken != null) {
                return byToken;
            }
        }

        List<PaymentOrderEntity> pending = paymentOrderMapper.selectList(
                Wrappers.<PaymentOrderEntity>lambdaQuery()
                        .eq(PaymentOrderEntity::getOrderNo, orderNo)
                        .eq(PaymentOrderEntity::getStatus, PaymentStatus.PENDING.code())
                        .orderByAsc(PaymentOrderEntity::getId));
        for (PaymentOrderEntity payment : pending) {
            if (channel.equalsIgnoreCase(payment.getChannel())) {
                return payment;
            }
        }
        if (!pending.isEmpty()) {
            // MVP：一个订单同时只有一笔活跃支付尝试，换渠道先关闭旧的
            paymentOrderMapper.closePendingByOrderNo(orderNo, now);
        }

        PaymentOrderEntity payment = new PaymentOrderEntity();
        payment.setPaymentNo(paymentNoGenerator.nextPaymentNo());
        payment.setOrderNo(orderNo);
        payment.setClientToken(clientToken == null || clientToken.isBlank() ? null : clientToken);
        payment.setUserId(userId);
        payment.setChannel(channel);
        // 金额只信服务端：不允许客户端传金额
        payment.setAmount(order.getPayAmount());
        payment.setStatus(PaymentStatus.PENDING.code());
        // 支付单不能比订单活得更久
        payment.setExpireAt(order.getExpireAt());
        paymentOrderMapper.insert(payment);
        return payment;
    }

    @Transactional
    public void markFailed(String paymentNo) {
        paymentOrderMapper.markFailed(paymentNo, LocalDateTime.now(ZoneOffset.UTC));
    }
}
