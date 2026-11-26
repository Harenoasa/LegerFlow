package com.ledgerflow.order.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.ledgerflow.order.entity.OrderStatusLogEntity;
import org.apache.ibatis.annotations.Mapper;

@Mapper
public interface OrderStatusLogMapper extends BaseMapper<OrderStatusLogEntity> {
}
