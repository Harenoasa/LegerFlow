package com.ledgerflow.order.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.ledgerflow.order.entity.OrderItemEntity;
import org.apache.ibatis.annotations.Mapper;

@Mapper
public interface OrderItemMapper extends BaseMapper<OrderItemEntity> {
}
