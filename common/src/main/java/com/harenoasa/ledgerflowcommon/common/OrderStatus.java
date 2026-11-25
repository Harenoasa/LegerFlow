package com.harenoasa.ledgerflowcommon.common;

/**
 * 订单状态。
 *
 * <p>code 必须与 {@code orders.order_status} 的取值保持一致（见
 * {@code V4__orders.sql}）。这是订单应用与支付服务共享的状态契约，
 * 支付模块不要再维护一套自己的状态常量。
 */
public enum OrderStatus {

    PENDING_PAYMENT(0, "待支付"),
    PAID(10, "已支付"),
    SHIPPED(20, "已发货"),
    COMPLETED(30, "已完成"),
    CANCELLED(40, "已取消"),
    AFTER_SALE(50, "售后中"),
    REFUNDED(60, "已退款");

    private final int code;
    private final String description;

    OrderStatus(int code, String description) {
        this.code = code;
        this.description = description;
    }

    public int code() {
        return code;
    }

    public String description() {
        return description;
    }

    public static OrderStatus fromCode(int code) {
        for (OrderStatus status : values()) {
            if (status.code == code) {
                return status;
            }
        }
        throw new IllegalArgumentException("未知订单状态: " + code);
    }
}
