package com.harenoasa.ledgerflow.payment.common;

import com.harenoasa.ledgerflowcommon.common.SnowflakeIdGenerator;
import jakarta.annotation.Resource;
import org.springframework.stereotype.Component;

/**
 * 支付/退款业务编号生成器。
 *
 * <p>payNo / refundNo 对外按字符串处理，数字部分与订单号一样超过 JavaScript
 * {@code Number.MAX_SAFE_INTEGER}，前端不能转 number。
 */
@Component
public class PaymentNoGenerator {

    private static final String PAYMENT_PREFIX = "PAY";
    private static final String REFUND_PREFIX = "REF";

    @Resource
    private SnowflakeIdGenerator snowflakeIdGenerator;

    public String nextPaymentNo() {
        return PAYMENT_PREFIX + snowflakeIdGenerator.nextId();
    }

    public String nextRefundNo() {
        return REFUND_PREFIX + snowflakeIdGenerator.nextId();
    }
}
