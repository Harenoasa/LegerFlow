package com.harenoasa.ledgerflowcommon.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import lombok.Data;

import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * 订单主表 orders。
 */
@Data
@TableName("orders")
public class OrdersEntity {

    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    private String orderNo;

    private Long userId;

    private String clientToken;

    private String requestHash;

    private Integer orderStatus;

    private BigDecimal totalAmount;

    private BigDecimal discountAmount;

    private BigDecimal freightAmount;

    private BigDecimal payAmount;

    private Long couponId;

    private String receiverName;

    private String receiverPhone;

    private String receiverProvince;

    private String receiverCity;

    private String receiverDistrict;

    private String receiverDetail;

    private String buyerRemark;

    private LocalDateTime expireAt;

    private LocalDateTime payTime;

    /** 成功结算该订单的支付单号；只有把订单推进到已支付的支付单才会写入。 */
    private String paidPaymentNo;

    private LocalDateTime shipTime;

    private LocalDateTime completeTime;

    private LocalDateTime cancelTime;

    private String cancelReason;

    private Integer version;

    private LocalDateTime createdAt;

    private LocalDateTime updatedAt;
}
