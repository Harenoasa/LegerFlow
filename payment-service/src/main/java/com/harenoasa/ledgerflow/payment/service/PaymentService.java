package com.harenoasa.ledgerflow.payment.service;

import com.baomidou.mybatisplus.core.toolkit.Wrappers;
import com.harenoasa.ledgerflow.payment.channel.PayChannel;
import com.harenoasa.ledgerflow.payment.channel.PayChannelRegistry;
import com.harenoasa.ledgerflow.payment.common.PaymentStatus;
import com.harenoasa.ledgerflow.payment.dto.CreatePaymentRequest;
import com.harenoasa.ledgerflow.payment.dto.PaymentResponse;
import com.harenoasa.ledgerflow.payment.entity.PaymentOrderEntity;
import com.harenoasa.ledgerflow.payment.mapper.PaymentOrderMapper;
import jakarta.annotation.Resource;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.web.server.ResponseStatusException;

/**
 * 创建/查询支付单。
 *
 * <p>数据库写入在 {@link PaymentRecordService} 的事务里完成；渠道预下单在事务提交后调用，
 * 失败只把支付单置为失败，订单仍保持待支付，用户可以重新发起。
 */
@Service
public class PaymentService {

    private static final Logger log = LoggerFactory.getLogger(PaymentService.class);

    @Resource
    private PaymentRecordService paymentRecordService;

    @Resource
    private PayChannelRegistry payChannelRegistry;

    @Resource
    private PaymentOrderMapper paymentOrderMapper;

    public PaymentResponse createPayment(Long userId, String orderNo, CreatePaymentRequest request) {
        PayChannel channel = payChannelRegistry.get(request.channel());
        PaymentOrderEntity payment = paymentRecordService.createOrReuse(
                userId, orderNo, channel.code(), request.clientToken());

        if (!Integer.valueOf(PaymentStatus.PENDING.code()).equals(payment.getStatus())) {
            // 复用到的支付单已经成功/失败/关闭，不再预下单
            return PaymentResponse.from(payment, null);
        }

        PayChannel.PrepayResult prepay;
        try {
            prepay = channel.prepay(new PayChannel.PrepayCommand(
                    payment.getPaymentNo(),
                    payment.getOrderNo(),
                    payment.getAmount(),
                    "订单 " + payment.getOrderNo(),
                    payment.getExpireAt()));
        } catch (RuntimeException e) {
            log.warn("渠道预下单失败，paymentNo={}, channel={}", payment.getPaymentNo(), channel.code(), e);
            paymentRecordService.markFailed(payment.getPaymentNo());
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY, "CHANNEL_ERROR", e);
        }
        return PaymentResponse.from(payment, prepay.payUrl());
    }

    public PaymentResponse getPayment(String paymentNo) {
        PaymentOrderEntity payment = paymentOrderMapper.selectOne(
                Wrappers.<PaymentOrderEntity>lambdaQuery()
                        .eq(PaymentOrderEntity::getPaymentNo, paymentNo));
        if (payment == null) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "PAYMENT_NOT_FOUND");
        }
        return PaymentResponse.from(payment, null);
    }
}
