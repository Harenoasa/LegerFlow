package com.ledgerflow.common;

/**
 * 支付单状态（payment_order.status）。
 *
 * <p>与订单状态是两套独立状态机：支付单可以失败、关闭，订单仍保持待支付。
 */
public enum PaymentStatus {

    PENDING(0, "PENDING_PAYMENT"),
    SUCCESS(1, "SUCCESS"),
    FAILED(2, "FAILED"),
    CLOSED(3, "CLOSED");

    private final int code;
    private final String label;

    PaymentStatus(int code, String label) {
        this.code = code;
        this.label = label;
    }

    public int code() {
        return code;
    }

    public String label() {
        return label;
    }

    public static PaymentStatus fromCode(Integer code) {
        if (code == null) {
            throw new IllegalArgumentException("支付状态不能为空");
        }
        for (PaymentStatus status : values()) {
            if (status.code == code) {
                return status;
            }
        }
        throw new IllegalArgumentException("未知支付状态: " + code);
    }

    public static String labelOf(Integer code) {
        return fromCode(code).label;
    }
}
