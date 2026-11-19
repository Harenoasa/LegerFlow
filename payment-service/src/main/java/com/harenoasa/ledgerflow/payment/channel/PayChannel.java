package com.harenoasa.ledgerflow.payment.channel;

import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * 渠道无关的支付渠道适配器。
 *
 * <p>新增支付宝/微信时只需要实现这个接口，支付主流程不用改。
 * 预下单等外部调用必须在数据库事务提交之后执行。
 */
public interface PayChannel {

    /** 渠道编码，例如 MOCK / ALIPAY / WECHAT。 */
    String code();

    /** 向渠道预下单，返回收银台地址。 */
    PrepayResult prepay(PrepayCommand command);

    /**
     * 验签并解析异步回调。
     *
     * @throws org.springframework.web.server.ResponseStatusException 验签失败或报文非法
     */
    CallbackMessage verifyAndParse(String rawBody, String signature);

    record PrepayCommand(String paymentNo,
                         String orderNo,
                         BigDecimal amount,
                         String subject,
                         LocalDateTime expireAt) {
    }

    record PrepayResult(String payUrl) {
    }

    /**
     * 渠道回调解析后的统一消息。
     *
     * @param success         渠道是否告知支付成功
     * @param externalTradeNo 渠道交易号，成功时必填
     * @param paidAt          渠道支付时间，可空；为空时使用服务端时间
     */
    record CallbackMessage(String notifyId,
                           String paymentNo,
                           BigDecimal amount,
                           boolean success,
                           String externalTradeNo,
                           LocalDateTime paidAt) {
    }
}
