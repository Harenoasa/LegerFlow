package com.ledgerflow.order.dto.response;

import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

/**
 * 创建订单响应：只返回下单成功后服务端确认的事实。
 */
@Data
@AllArgsConstructor
@NoArgsConstructor
public class CreateOrderResponseDTO {

    private String orderNo;

    private String orderStatus;

    public static CreateOrderResponseDTO pending(String orderNo) {
        return new CreateOrderResponseDTO(orderNo, "PENDING_PAYMENT");
    }
}
