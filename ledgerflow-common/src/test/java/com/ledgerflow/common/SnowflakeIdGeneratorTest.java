package com.ledgerflow.common;

import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SnowflakeIdGeneratorTest {

    @Test
    void generatesStrictlyIncreasingIds() {
        SnowflakeIdGenerator generator = new SnowflakeIdGenerator(1, 1);

        long previous = generator.nextId();
        for (int i = 0; i < 10_000; i++) {
            long current = generator.nextId();
            assertTrue(current > previous, "ID 必须严格递增");
            previous = current;
        }
    }

    @Test
    void generatesUniqueIdsUnderConcurrency() throws Exception {
        SnowflakeIdGenerator generator = new SnowflakeIdGenerator(1, 1);
        int threads = 8;
        int idsPerThread = 5_000;

        Set<Long> ids = ConcurrentHashMap.newKeySet();
        CountDownLatch start = new CountDownLatch(1);
        ExecutorService pool = Executors.newFixedThreadPool(threads);
        try {
            List<Future<?>> futures = new ArrayList<>();
            for (int i = 0; i < threads; i++) {
                futures.add(pool.submit(() -> {
                    start.await();
                    for (int j = 0; j < idsPerThread; j++) {
                        assertTrue(ids.add(generator.nextId()), "生成了重复 ID");
                    }
                    return null;
                }));
            }
            start.countDown();
            for (Future<?> future : futures) {
                future.get();
            }
        } finally {
            pool.shutdownNow();
        }

        assertEquals(threads * idsPerThread, ids.size());
    }

    @Test
    void rejectsOutOfRangeWorkerAndDatacenterIds() {
        assertThrows(IllegalArgumentException.class, () -> new SnowflakeIdGenerator(-1, 0));
        assertThrows(IllegalArgumentException.class, () -> new SnowflakeIdGenerator(32, 0));
        assertThrows(IllegalArgumentException.class, () -> new SnowflakeIdGenerator(0, -1));
        assertThrows(IllegalArgumentException.class, () -> new SnowflakeIdGenerator(0, 32));
    }

    @Test
    void orderNoHasLfPrefixAndNumericSnowflake() {
        OrderNoGenerator orderNoGenerator = new OrderNoGenerator();
        ReflectionTestUtils.setField(orderNoGenerator, "snowflakeIdGenerator",
                new SnowflakeIdGenerator(1, 1));

        String orderNo = orderNoGenerator.next();

        assertTrue(orderNo.matches("LF\\d{18,19}"), "订单号应为 LF + 18~19 位数字");
        assertTrue(Long.parseLong(orderNo.substring(2)) > 0);
    }
}
