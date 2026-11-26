package com.ledgerflow.payment.controller;

import com.baomidou.mybatisplus.core.toolkit.Wrappers;
import com.ledgerflow.payment.channel.MockPayChannel;
import com.ledgerflow.payment.channel.PayChannel;
import com.ledgerflow.payment.dto.MockPayRequest;
import com.ledgerflow.payment.entity.PaymentOrderEntity;
import com.ledgerflow.payment.mapper.PaymentOrderMapper;
import com.ledgerflow.payment.service.PaymentCallbackService;
import jakarta.annotation.Resource;
import org.springframework.context.annotation.Profile;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.Map;
import java.util.UUID;

/**
 * 仅 dev profile 使用的 Mock 收银台。
 *
 * <p>它模拟“渠道异步通知”：生成带签名的回调报文，再走与真实渠道完全相同的
 * {@link PaymentCallbackService} 验签、幂等、状态推进链路。
 *
 * <p>启动方式：{@code --spring.profiles.active=dev}
 */
@RestController
@Profile("dev")
@RequestMapping("/api/mock-channel")
public class MockChannelController {

    @Resource
    private PaymentOrderMapper paymentOrderMapper;

    @Resource
    private MockPayChannel mockPayChannel;

    @Resource
    private PaymentCallbackService paymentCallbackService;

    @PostMapping("/pay/{paymentNo}")
    public Map<String, Object> pay(@PathVariable String paymentNo,
                                   @RequestBody(required = false) MockPayRequest request) {
        PaymentOrderEntity payment = paymentOrderMapper.selectOne(
                Wrappers.<PaymentOrderEntity>lambdaQuery()
                        .eq(PaymentOrderEntity::getPaymentNo, paymentNo));
        if (payment == null) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "PAYMENT_NOT_FOUND");
        }

        boolean success = request == null || request.successOrDefault();
        String notifyId = "MOCK-N-" + UUID.randomUUID().toString().replace("-", "");
        String externalTradeNo = success
                ? "MOCK-T-" + UUID.randomUUID().toString().replace("-", "")
                : null;
        PayChannel.CallbackMessage message = new PayChannel.CallbackMessage(
                notifyId,
                paymentNo,
                payment.getAmount(),
                success,
                externalTradeNo,
                success ? LocalDateTime.now(ZoneOffset.UTC) : null);

        String rawBody = mockPayChannel.serialize(message);
        String signature = mockPayChannel.sign(rawBody);
        paymentCallbackService.handle(MockPayChannel.CODE, rawBody, signature);

        return Map.of(
                "result", "CALLBACK_PROCESSED",
                "notifyId", notifyId,
                "paymentNo", paymentNo);
    }
}
