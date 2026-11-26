package com.ledgerflow.common;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.time.Instant;

/**
 * 雪花算法 ID 生成器：41 位毫秒时间戳 + 5 位数据中心 + 5 位机器 + 12 位序列号。
 *
 * <p>单节点每毫秒最多生成 4096 个 ID。起始纪元为 2024-01-01T00:00:00Z，
 * 41 位时间戳可用约 69 年。多实例部署时必须为每个实例配置不同的
 * {@code ledgerflow.snowflake.worker-id} / {@code ledgerflow.snowflake.datacenter-id}
 * （可通过 {@code SNOWFLAKE_WORKER_ID} / {@code SNOWFLAKE_DATACENTER_ID} 环境变量覆盖），
 * 否则不同实例可能生成相同 ID。
 *
 * <p>时钟回拨处理：回拨不超过 5ms 时等待时钟追上；超过 5ms 直接抛异常，
 * 宁可让本次请求失败，也不生成可能重复的 ID。
 */
@Component
public class SnowflakeIdGenerator {

    private static final long EPOCH = Instant.parse("2024-01-01T00:00:00Z").toEpochMilli();

    private static final long WORKER_ID_BITS = 5L;
    private static final long DATACENTER_ID_BITS = 5L;
    private static final long SEQUENCE_BITS = 12L;

    private static final long MAX_WORKER_ID = ~(-1L << WORKER_ID_BITS);
    private static final long MAX_DATACENTER_ID = ~(-1L << DATACENTER_ID_BITS);
    private static final long SEQUENCE_MASK = ~(-1L << SEQUENCE_BITS);

    private static final long WORKER_ID_SHIFT = SEQUENCE_BITS;
    private static final long DATACENTER_ID_SHIFT = SEQUENCE_BITS + WORKER_ID_BITS;
    private static final long TIMESTAMP_SHIFT = SEQUENCE_BITS + WORKER_ID_BITS + DATACENTER_ID_BITS;

    private static final long MAX_CLOCK_BACKWARD_WAIT_MILLIS = 5L;

    private final long workerId;
    private final long datacenterId;

    private long lastTimestamp = -1L;
    private long sequence = 0L;

    public SnowflakeIdGenerator(
            @Value("${ledgerflow.snowflake.worker-id:0}") long workerId,
            @Value("${ledgerflow.snowflake.datacenter-id:0}") long datacenterId) {
        if (workerId < 0 || workerId > MAX_WORKER_ID) {
            throw new IllegalArgumentException("workerId 必须在 0~" + MAX_WORKER_ID + " 之间");
        }
        if (datacenterId < 0 || datacenterId > MAX_DATACENTER_ID) {
            throw new IllegalArgumentException("datacenterId 必须在 0~" + MAX_DATACENTER_ID + " 之间");
        }
        this.workerId = workerId;
        this.datacenterId = datacenterId;
    }

    public synchronized long nextId() {
        long timestamp = System.currentTimeMillis();
        if (timestamp < EPOCH) {
            throw new IllegalStateException("系统时钟早于雪花算法起始纪元，无法生成 ID");
        }

        if (timestamp < lastTimestamp) {
            long backwardMillis = lastTimestamp - timestamp;
            if (backwardMillis > MAX_CLOCK_BACKWARD_WAIT_MILLIS) {
                throw new IllegalStateException(
                        "系统时钟回拨 " + backwardMillis + "ms，拒绝生成 ID");
            }
            timestamp = waitUntil(lastTimestamp);
        }

        if (timestamp == lastTimestamp) {
            sequence = (sequence + 1) & SEQUENCE_MASK;
            if (sequence == 0) {
                timestamp = waitNextMillis(lastTimestamp);
            }
        } else {
            sequence = 0L;
        }

        lastTimestamp = timestamp;
        return ((timestamp - EPOCH) << TIMESTAMP_SHIFT)
                | (datacenterId << DATACENTER_ID_SHIFT)
                | (workerId << WORKER_ID_SHIFT)
                | sequence;
    }

    private static long waitUntil(long targetTimestamp) {
        long timestamp = System.currentTimeMillis();
        while (timestamp < targetTimestamp) {
            Thread.onSpinWait();
            timestamp = System.currentTimeMillis();
        }
        return timestamp;
    }

    private static long waitNextMillis(long lastTimestamp) {
        long timestamp = System.currentTimeMillis();
        while (timestamp <= lastTimestamp) {
            Thread.onSpinWait();
            timestamp = System.currentTimeMillis();
        }
        return timestamp;
    }
}
