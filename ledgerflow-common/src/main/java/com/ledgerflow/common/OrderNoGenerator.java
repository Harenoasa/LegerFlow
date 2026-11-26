package com.ledgerflow.common;

import jakarta.annotation.Resource;
import org.springframework.stereotype.Component;

/**
 * 订单编号生成器：LF + 雪花算法生成的对外订单号，例如 LF373271725637632000。
 *
 * <p>order_no 对外始终按字符串处理（数字部分 18~19 位，已超过 JavaScript
 * {@code Number.MAX_SAFE_INTEGER}，前端用 number 会丢精度）。
 * 多实例部署时需为每个实例配置不同的雪花 workerId/datacenterId，保证全局唯一。
 */
@Component
public class OrderNoGenerator {

    private static final String PREFIX = "LF";

    @Resource
    private SnowflakeIdGenerator snowflakeIdGenerator;

    /**
     * 使用雪花算法生成订单号。
     *
     * @return String
     */
    public String next() {
        return PREFIX + snowflakeIdGenerator.nextId();
    }
}
