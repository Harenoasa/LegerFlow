package com.ledgerflow.order.dto.request;

import jakarta.validation.Valid;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Positive;
import jakarta.validation.constraints.Size;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.math.BigDecimal;
import java.util.List;

/**
 * 创建订单请求。
 *
 * <p>只接收“下单意图”字段，金额、商品快照、收货地址快照、订单状态均由服务端生成。
 */
@Data
@NoArgsConstructor
public class CreateOrderRequest {

    /**
     * 客户端幂等键。
     *
     * <p>推荐通过 Header {@code Idempotency-Key} 传递；保留该字段用于不方便设置
     * 自定义 Header 的客户端，两者二选一。同一个 token 的重试返回同一订单。
     *
     *
     */
//    @Pattern(
//            regexp = "^[A-Za-z0-9_-]{8,64}$",
//            message = "clientToken 格式不正确"
//    )
//    private String clientToken;
//    备注：弃用，改为控制层直接传递参数

    /**
     * 收货地址 ID，对应 user_address.id。
     */
    @NotNull(message = "addressId 不能为空")
    @Positive(message = "addressId 必须大于 0")
    private Long addressId;

    /**
     * 用户优惠券 ID，对应 user_coupon.id；一单最多使用一张。
     */
    @Positive(message = "userCouponId 必须大于 0")
    private Long userCouponId;

    /**
     * 订单明细，至少 1 行，最多 100 行。
     */
    @NotEmpty(message = "items 不能为空")
    @Size(max = 100, message = "items 最多 100 行")
    private List<@NotNull(message = "items 不能包含空行") @Valid CreateOrderItemRequest> items;

    /**
     * 买家备注，对应 orders.buyer_remark。
     */
    @Size(max = 255, message = "buyerRemark 不能超过 255 个字符")
    private String buyerRemark;

    /**
     * 客户端期望的应付金额，用于价格变化检测；不落库。
     *
     * <p>不传则跳过该校验；传入且与服务端重算结果不一致时返回 PRICE_CHANGED。
     */
    @DecimalMin(value = "0.00", message = "expectedPayAmount 不能小于 0")
    @Digits(integer = 16, fraction = 2, message = "expectedPayAmount 最多 16 位整数、2 位小数")
    private BigDecimal expectedPayAmount;

    /**
     * 支付渠道；仅“下单并拉起支付”的场景使用，否则走独立支付接口。
     */
    @Pattern(
            regexp = "ALIPAY|WECHAT|BALANCE",
            message = "payChannel 只支持 ALIPAY、WECHAT、BALANCE"
    )
    private String payChannel;

    /**
     * 下单来源，如 H5、APP、MINI_PROGRAM；当前表无对应列，预留给后续扩展。
     */
    @Size(max = 32, message = "source 不能超过 32 个字符")
    private String source;
}
