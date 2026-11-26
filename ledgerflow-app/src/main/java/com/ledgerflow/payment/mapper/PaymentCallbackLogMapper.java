package com.ledgerflow.payment.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.ledgerflow.payment.entity.PaymentCallbackLogEntity;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface PaymentCallbackLogMapper extends BaseMapper<PaymentCallbackLogEntity> {

    /**
     * 回调幂等闸门：必须作为事务里的第一句执行。
     *
     * <p>并发重复通知会在 uk_channel_notify 上阻塞，第一个事务提交后第二个返回 0；
     * 第一个事务回滚时，第二个可以继续正常处理。
     */
    @Insert("""
            INSERT IGNORE INTO payment_callback_log
                (notify_id, payment_no, channel, raw_body, process_status)
            VALUES
                (#{notifyId}, #{paymentNo}, #{channel}, #{rawBody}, 0)
            """)
    int insertIgnore(@Param("notifyId") String notifyId,
                     @Param("paymentNo") String paymentNo,
                     @Param("channel") String channel,
                     @Param("rawBody") String rawBody);

    @Select("""
            SELECT process_status
            FROM payment_callback_log
            WHERE channel = #{channel}
              AND notify_id = #{notifyId}
            """)
    Integer selectProcessStatus(@Param("channel") String channel,
                                @Param("notifyId") String notifyId);

    @Update("""
            UPDATE payment_callback_log
            SET process_status = #{processStatus},
                error_msg = #{errorMsg},
                processed_at = NOW(3)
            WHERE channel = #{channel}
              AND notify_id = #{notifyId}
            """)
    int markProcessed(@Param("channel") String channel,
                      @Param("notifyId") String notifyId,
                      @Param("processStatus") int processStatus,
                      @Param("errorMsg") String errorMsg);
}
