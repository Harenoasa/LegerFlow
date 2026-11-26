package com.ledgerflow.payment.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import lombok.Data;

import java.time.LocalDateTime;

/**
 * 支付回调日志 payment_callback_log。
 *
 * <p>{@code uk_channel_notify(channel, notify_id)} 是回调幂等的第一道闸门：
 * 与业务写在同一事务里先 INSERT IGNORE，重复通知会在这里被挡住。
 */
@Data
@TableName("payment_callback_log")
public class PaymentCallbackLogEntity {

    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    private String notifyId;

    private String paymentNo;

    private String channel;

    private String rawBody;

    /** 0=已接收，1=处理成功，2=处理失败。 */
    private Integer processStatus;

    private String errorMsg;

    private LocalDateTime processedAt;

    private LocalDateTime createdAt;
}
