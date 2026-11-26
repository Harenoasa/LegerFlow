package com.ledgerflow.payment.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * 创建支付尝试的请求。
 *
 * @param channel     MOCK / ALIPAY / WECHAT / BALANCE
 * @param clientToken 客户端支付意图幂等键，同一个 token 重复请求复用同一笔支付单
 */
public record CreatePaymentRequest(
        @NotBlank(message = "channel 不能为空")
        @Size(max = 32, message = "channel 长度不能超过 32")
        String channel,

        @Size(max = 64, message = "clientToken 长度不能超过 64")
        String clientToken) {
}
