package com.harenoasa.ledgerflow.payment;

import com.harenoasa.ledgerflowcommon.common.SnowflakeIdGenerator;
import org.mybatis.spring.annotation.MapperScan;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Import;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * 支付服务入口。
 *
 * <p>当前与 ledgerflow-common 共用同一个 MySQL 库：支付回调必须在同一个本地事务里
 * 完成 payment_order、orders、inventory、order_status_log、outbox_event 的写入，
 * 因此拆成独立进程时仍然共库，而不是跨服务调用。
 *
 * <p>组件扫描只覆盖 payment 包；共享实体和 Mapper 通过显式 {@link MapperScan} 引入，
 * 雪花 ID 生成器通过 {@link Import} 引入，避免把 ledgerflow-common 的 Controller 也加载进来。
 */
@SpringBootApplication
@EnableScheduling
@MapperScan({
        "com.harenoasa.ledgerflow.payment.mapper",
        "com.harenoasa.ledgerflowcommon.mapper"
})
@Import(SnowflakeIdGenerator.class)
public class PaymentServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(PaymentServiceApplication.class, args);
    }
}
