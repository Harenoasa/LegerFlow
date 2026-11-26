package com.ledgerflow.outbox;

import com.ledgerflow.outbox.entity.OutboxEventEntity;
import com.ledgerflow.outbox.mapper.OutboxEventMapper;
import jakarta.annotation.Resource;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.ObjectMapper;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.concurrent.TimeUnit;

/**
 * Outbox 投递器：把 outbox_event 里的待发布事件发送到 Kafka。
 *
 * <p>默认关闭（{@code ledgerflow.outbox.publisher-enabled=false}），因为本地不一定起了 Kafka。
 * 打开后按 {@code status IN (0,2)} + 退避时间扫描，发送成功置为已发布，失败保留并指数退避。
 *
 * <p>MVP 单实例在事务内发送，发送超时设 3 秒；多实例依赖
 * {@code FOR UPDATE SKIP LOCKED} 抢批次，后续可扩展“发送中 + 租约”避免长事务。
 */
@Component
@ConditionalOnProperty(prefix = "ledgerflow.outbox", name = "publisher-enabled", havingValue = "true")
public class OutboxPublisher {

    private static final Logger log = LoggerFactory.getLogger(OutboxPublisher.class);

    @Resource
    private OutboxEventMapper outboxEventMapper;

    @Resource
    private KafkaTemplate<String, String> kafkaTemplate;

    @Resource
    private ObjectMapper objectMapper;

    @Value("${ledgerflow.outbox.batch-size:100}")
    private int batchSize;

    @Value("${ledgerflow.outbox.payment-topic:ledgerflow.payment.events.v1}")
    private String paymentTopic;

    @Value("${ledgerflow.outbox.refund-topic:ledgerflow.refund.events.v1}")
    private String refundTopic;

    @Scheduled(fixedDelayString = "${ledgerflow.outbox.poll-interval-ms:1000}")
    @Transactional
    public void publishBatch() {
        List<OutboxEventEntity> batch = outboxEventMapper.lockPendingBatch(batchSize);
        for (OutboxEventEntity event : batch) {
            String topic = "REFUND".equalsIgnoreCase(event.getAggregateType())
                    ? refundTopic : paymentTopic;
            String key = eventKey(event);
            try {
                kafkaTemplate.send(topic, key, event.getPayload()).get(3, TimeUnit.SECONDS);
                outboxEventMapper.markPublished(event.getId());
                log.debug("Outbox 投递成功: eventId={}, topic={}, key={}",
                        event.getEventId(), topic, key);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                markRetry(event, "投递被中断");
                return;
            } catch (Exception e) {
                markRetry(event, e.getMessage());
            }
        }
    }

    private void markRetry(OutboxEventEntity event, String reason) {
        int retryCount = event.getRetryCount() == null ? 1 : event.getRetryCount() + 1;
        long delaySeconds = Math.min(1L << Math.min(retryCount, 8), 300);
        LocalDateTime nextRetryAt = LocalDateTime.now(ZoneOffset.UTC).plusSeconds(delaySeconds);
        outboxEventMapper.markFailed(event.getId(), retryCount, nextRetryAt);
        log.warn("Outbox 投递失败，{}s 后重试: eventId={}, retryCount={}, reason={}",
                delaySeconds, event.getEventId(), retryCount, reason);
    }

    /**
     * 同一订单的事件必须进同一分区，key 用 payload 里的 orderNo，而不是 paymentNo。
     */
    private String eventKey(OutboxEventEntity event) {
        try {
            JsonNode root = objectMapper.readTree(event.getPayload());
            String orderNo = root.path("payload").path("orderNo").asString(null);
            if (orderNo != null && !orderNo.isBlank()) {
                return orderNo;
            }
        } catch (JacksonException e) {
            log.warn("解析 outbox 事件 payload 失败，降级用 aggregateId 作为 key: eventId={}",
                    event.getEventId());
        }
        return event.getAggregateId();
    }
}
