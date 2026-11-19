package com.harenoasa.ledgerflow.payment.mapper;

import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Update;

/**
 * 支付成功时的库存操作。
 *
 * <p>库存流水先插，作为业务幂等闸门；只有流水插入成功才更新库存，
 * 这样重复消费/重复回调不会重复扣减。
 */
@Mapper
public interface InventoryOperationMapper {

    /**
     * 支付成功：库存从“锁定”转“已售”，available_stock 不变。
     *
     * <p>用 INSERT ... SELECT 直接从 inventory 取 available_stock，
     * 省一次查询；唯一键 uk_biz(biz_type, biz_no, sku_id, change_type) 负责去重。
     *
     * @return 1=新插入，0=已存在或库存行不存在
     */
    @Insert("""
            INSERT IGNORE INTO inventory_log
                (sku_id, change_type, change_qty, before_available, after_available,
                 biz_type, biz_no, remark)
            SELECT sku_id, 3, #{quantity}, available_stock, available_stock,
                   'ORDER_PAY', #{paymentNo}, '支付成功：锁定转已售'
            FROM inventory
            WHERE sku_id = #{skuId}
            """)
    int insertPayLogIfAbsent(@Param("paymentNo") String paymentNo,
                             @Param("skuId") Long skuId,
                             @Param("quantity") int quantity);

    /**
     * 只有 locked_stock 足够时才推进，影响 0 行说明库存已经被其他流程动过，
     * 上层必须回滚并告警。
     */
    @Update("""
            UPDATE inventory
            SET locked_stock = locked_stock - #{quantity},
                sold_stock = sold_stock + #{quantity},
                version = version + 1
            WHERE sku_id = #{skuId}
              AND locked_stock >= #{quantity}
            """)
    int moveLockedToSold(@Param("skuId") Long skuId,
                         @Param("quantity") int quantity);
}
