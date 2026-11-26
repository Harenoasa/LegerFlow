package com.ledgerflow.outbox.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.ledgerflow.outbox.entity.OutboxEventEntity;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

import java.time.LocalDateTime;
import java.util.List;

@Mapper
public interface OutboxEventMapper extends BaseMapper<OutboxEventEntity> {

    /**
     * 多实例安全地抢一批待发布事件。发送期间持有行锁，发送超时必须设短。
     */
    @Select("""
            SELECT id, event_id, aggregate_type, aggregate_id, event_type, payload,
                   status, retry_count, next_retry_at, published_at, created_at, updated_at
            FROM outbox_event
            WHERE status IN (0, 2)
              AND (next_retry_at IS NULL OR next_retry_at <= NOW(3))
            ORDER BY id
            LIMIT #{limit}
            FOR UPDATE SKIP LOCKED
            """)
    List<OutboxEventEntity> lockPendingBatch(@Param("limit") int limit);

    @Update("""
            UPDATE outbox_event
            SET status = 1,
                published_at = NOW(3),
                updated_at = NOW(3)
            WHERE id = #{id}
            """)
    int markPublished(@Param("id") Long id);

    @Update("""
            UPDATE outbox_event
            SET status = 2,
                retry_count = #{retryCount},
                next_retry_at = #{nextRetryAt},
                updated_at = NOW(3)
            WHERE id = #{id}
            """)
    int markFailed(@Param("id") Long id,
                   @Param("retryCount") int retryCount,
                   @Param("nextRetryAt") LocalDateTime nextRetryAt);
}
