package com.harenoasa.ledgerflowcommon.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.harenoasa.ledgerflowcommon.entity.OrdersEntity;
import org.apache.ibatis.annotations.Mapper;

@Mapper
public interface OrdersMapper extends BaseMapper<OrdersEntity> {
}
