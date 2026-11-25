package com.harenoasa.ledgerflowcommon.dto.request;

import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;
import lombok.Data;
import lombok.NoArgsConstructor;

/**
 * 创建订单的明细行请求。
 *
 * <p>只传 skuId 和数量；商品名称、规格、图片、单价均由服务端按当前 SKU 快照生成。
 */
@Data
@NoArgsConstructor
public class CreateOrderItemRequest {

    /**
     * SKU ID，对应 product_sku.id。
     */
    @NotNull(message = "skuId 不能为空")
    @Positive(message = "skuId 必须大于 0")
    private Long skuId;

    /**
     * 购买数量。
     */
    @NotNull(message = "quantity 不能为空")
    @Min(value = 1, message = "quantity 至少为 1")
    @Max(value = 999, message = "quantity 不能超过 999")
    private Integer quantity;

    /**
     * 购物车行 ID，仅购物车结算时传递；用于校验并清理购物车，不作为价格来源。
     */
    @Positive(message = "cartItemId 必须大于 0")
    private Long cartItemId;
}
