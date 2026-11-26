package com.ledgerflow.payment.dto;

/**
 * Mock 渠道支付结果。
 *
 * @param success 是否模拟支付成功；缺省为 true
 */
public record MockPayRequest(Boolean success) {

    public boolean successOrDefault() {
        return success == null || success;
    }
}
