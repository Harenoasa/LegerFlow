package com.harenoasa.ledgerflow.payment.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.harenoasa.ledgerflow.payment.entity.RefundOrderEntity;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

import java.math.BigDecimal;

@Mapper
public interface RefundOrderMapper extends BaseMapper<RefundOrderEntity> {

    /**
     * 已占用（申请/处理中/成功）的退款金额。调用方必须已经持有 payment_order 行锁，
     * 否则并发退款可能同时通过上限校验。
     */
    @Select("""
            SELECT COALESCE(SUM(amount), 0)
            FROM refund_order
            WHERE payment_no = #{paymentNo}
              AND status IN (0, 1, 2)
            """)
    BigDecimal sumReservedAmount(@Param("paymentNo") String paymentNo);
}
