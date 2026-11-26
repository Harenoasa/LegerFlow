package com.ledgerflow.inventory.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.ledgerflow.inventory.entity.InventoryEntity;
import org.apache.ibatis.annotations.Mapper;

@Mapper
public interface InventoryMapper extends BaseMapper<InventoryEntity> {
}
