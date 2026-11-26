package com.ledgerflow.outbox.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import lombok.Data;

import java.time.LocalDateTime;

/**
 * 事务性发件箱 outbox_event。
 *
 * <p>事件和业务写在同一事务里，OutboxPublisher 再把事件投递到 Kafka。
 */
@Data
@TableName("outbox_event")
public class OutboxEventEntity {

    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    private String eventId;

    /** ORDER / PAYMENT / REFUND。 */
    private String aggregateType;

    private String aggregateId;

    private String eventType;

    /** JSON 文本，MySQL JSON 列。 */
    private String payload;

    /** 0=待发布，1=已发布，2=发布失败。 */
    private Integer status;

    private Integer retryCount;

    private LocalDateTime nextRetryAt;

    private LocalDateTime publishedAt;

    private LocalDateTime createdAt;

    private LocalDateTime updatedAt;
}
