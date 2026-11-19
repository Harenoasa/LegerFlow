package com.harenoasa.ledgerflow.payment.controller;

import com.harenoasa.ledgerflow.payment.dto.CreatePaymentRequest;
import com.harenoasa.ledgerflow.payment.dto.PaymentResponse;
import com.harenoasa.ledgerflow.payment.service.PaymentCallbackService;
import com.harenoasa.ledgerflow.payment.service.PaymentService;
import jakarta.annotation.Resource;
import jakarta.validation.Valid;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * 支付接口。
 *
 * <p>userId 暂由 {@code X-User-Id} 模拟登录态，接入认证后改为从 Token 获取。
 */
@RestController
@RequestMapping("/api")
public class PaymentController {

    @Resource
    private PaymentService paymentService;

    @Resource
    private PaymentCallbackService paymentCallbackService;

    /**
     * 为待支付订单创建/复用一个支付尝试。
     */
    @PostMapping("/orders/{orderNo}/payments")
    public ResponseEntity<PaymentResponse> createPayment(
            @RequestHeader(value = "X-User-Id", defaultValue = "1") Long userId,
            @PathVariable String orderNo,
            @Valid @RequestBody CreatePaymentRequest request) {
        PaymentResponse response = paymentService.createPayment(userId, orderNo, request);
        return ResponseEntity
                .status(HttpStatus.CREATED)
                .header(HttpHeaders.LOCATION, "/api/payments/" + response.paymentNo())
                .body(response);
    }

    /**
     * 前端轮询支付状态。
     */
    @GetMapping("/payments/{paymentNo}")
    public PaymentResponse getPayment(@PathVariable String paymentNo) {
        return paymentService.getPayment(paymentNo);
    }

    /**
     * 渠道异步回调。验签失败返回 401，业务异常返回 5xx，渠道会重试。
     */
    @PostMapping("/payments/callback/{channel}")
    public ResponseEntity<Map<String, Object>> callback(
            @PathVariable String channel,
            @RequestHeader(value = "X-Pay-Signature", required = false) String signature,
            @RequestBody String rawBody) {
        paymentCallbackService.handle(channel, rawBody, signature);
        return ResponseEntity.ok(Map.of("code", "SUCCESS"));
    }
}
