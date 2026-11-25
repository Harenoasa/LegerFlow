package com.harenoasa.ledgerflowcommon.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import lombok.Data;

import java.time.LocalDateTime;

/**
 * 商品 SPU 表 product_spu。
 */
@Data
@TableName("product_spu")
public class ProductSpuEntity {

    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    private String title;

    private String mainImageUrl;

    private Integer status;

    private LocalDateTime deletedAt;
}
