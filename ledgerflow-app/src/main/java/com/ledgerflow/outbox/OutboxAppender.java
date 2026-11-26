package com.ledgerflow.outbox;

import com.ledgerflow.outbox.entity.OutboxEventEntity;
import com.ledgerflow.outbox.mapper.OutboxEventMapper;
import jakarta.annotation.Resource;
import org.springframework.stereotype.Component;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.ObjectMapper;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

/**
 * 事务性发件箱写入器。
 *
 * <p>必须在业务事务内调用：业务变更和事件记录一起提交或一起回滚，
 * Kafka 投递由 {@link OutboxPublisher} 在事务外完成。
 */
@Component
public class OutboxAppender {

    private static final int EVENT_VERSION = 1;

    @Resource
    private OutboxEventMapper outboxEventMapper;

    @Resource
    private ObjectMapper objectMapper;

    /**
     * @param aggregateType ORDER / PAYMENT / REFUND
     * @param aggregateId   聚合业务号
     * @param eventType     例如 PAYMENT_SUCCEEDED
     * @param payload       业务字段，会放进事件信封的 payload 中
     */
    public void append(String aggregateType,
                       String aggregateId,
                       String eventType,
                       Map<String, Object> payload) {
        String eventId = UUID.randomUUID().toString().replace("-", "");

        Map<String, Object> envelope = new LinkedHashMap<>();
        envelope.put("eventId", eventId);
        envelope.put("eventType", eventType);
        envelope.put("eventVersion", EVENT_VERSION);
        envelope.put("occurredAt", LocalDateTime.now(ZoneOffset.UTC).toString());
        envelope.put("aggregateType", aggregateType);
        envelope.put("aggregateId", aggregateId);
        envelope.put("payload", payload);

        String json;
        try {
            json = objectMapper.writeValueAsString(envelope);
        } catch (JacksonException e) {
            throw new IllegalStateException("序列化 outbox 事件失败", e);
        }

        OutboxEventEntity event = new OutboxEventEntity();
        event.setEventId(eventId);
        event.setAggregateType(aggregateType);
        event.setAggregateId(aggregateId);
        event.setEventType(eventType);
        event.setPayload(json);
        event.setStatus(0);
        event.setRetryCount(0);
        outboxEventMapper.insert(event);
    }
}
