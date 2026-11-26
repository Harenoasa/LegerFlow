package com.ledgerflow.payment.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.ledgerflow.payment.entity.PaymentOrderEntity;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

import java.time.LocalDateTime;

@Mapper
public interface PaymentOrderMapper extends BaseMapper<PaymentOrderEntity> {

    /**
     * 加行锁读取支付单。加锁顺序必须是 orders -> payment_order，和关单任务保持一致。
     */
    @Select("SELECT * FROM payment_order WHERE payment_no = #{paymentNo} FOR UPDATE")
    PaymentOrderEntity selectForUpdateByPaymentNo(@Param("paymentNo") String paymentNo);

    @Select("SELECT order_no FROM payment_order WHERE payment_no = #{paymentNo}")
    String selectOrderNoByPaymentNo(@Param("paymentNo") String paymentNo);

    /**
     * 条件更新：任何“尚未成功”的支付单都可以变成成功，重复回调会返回 0 行。
     *
     * <p>除了待支付(0)，还允许已关闭(3)和失败(2)：
     * 超时关单会关闭支付单，渠道可能在之后才通知成功；渠道也可能先发失败、后发成功。
     * 钱确实到账就必须记录，订单已不可支付时由回调服务创建退款。
     */
    @Update("""
            UPDATE payment_order
            SET status = 1,
                external_trade_no = #{externalTradeNo},
                paid_at = #{paidAt},
                updated_at = NOW(3)
            WHERE payment_no = #{paymentNo}
              AND status <> 1
            """)
    int markSuccess(@Param("paymentNo") String paymentNo,
                    @Param("externalTradeNo") String externalTradeNo,
                    @Param("paidAt") LocalDateTime paidAt);

    /**
     * 渠道回调明确失败，或渠道预下单失败：只关闭支付单，订单仍保持待支付。
     */
    @Update("""
            UPDATE payment_order
            SET status = 2,
                closed_at = #{closedAt},
                updated_at = NOW(3)
            WHERE payment_no = #{paymentNo}
              AND status = 0
            """)
    int markFailed(@Param("paymentNo") String paymentNo,
                   @Param("closedAt") LocalDateTime closedAt);

    /**
     * 关闭同一订单下其他待支付尝试（换渠道 / 重复发起）。
     */
    @Update("""
            UPDATE payment_order
            SET status = 3,
                closed_at = #{closedAt},
                updated_at = NOW(3)
            WHERE order_no = #{orderNo}
              AND status = 0
            """)
    int closePendingByOrderNo(@Param("orderNo") String orderNo,
                              @Param("closedAt") LocalDateTime closedAt);
}
