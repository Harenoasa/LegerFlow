package com.ledgerflow.payment.service;

import com.baomidou.mybatisplus.core.toolkit.Wrappers;
import com.ledgerflow.payment.channel.PayChannel;
import com.ledgerflow.payment.channel.PayChannelRegistry;
import com.ledgerflow.common.PaymentStatus;
import com.ledgerflow.payment.entity.PaymentOrderEntity;
import com.ledgerflow.inventory.mapper.InventoryOperationMapper;
import com.ledgerflow.payment.mapper.PaymentCallbackLogMapper;
import com.ledgerflow.payment.mapper.PaymentOrderMapper;
import com.ledgerflow.outbox.OutboxAppender;
import com.ledgerflow.common.OrderStatus;
import com.ledgerflow.order.entity.OrderItemEntity;
import com.ledgerflow.order.entity.OrderStatusLogEntity;
import com.ledgerflow.order.entity.OrdersEntity;
import com.ledgerflow.order.mapper.OrderItemMapper;
import com.ledgerflow.order.mapper.OrderStatusLogMapper;
import com.ledgerflow.order.mapper.OrdersMapper;
import jakarta.annotation.Resource;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.server.ResponseStatusException;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 支付回调事务（支付模块最核心的一条链路）。
 *
 * <p>同一个本地事务内按固定顺序完成：
 * <ol>
 *   <li>payment_callback_log 幂等闸门</li>
 *   <li>锁 orders -> payment_order（与关单任务保持相同加锁顺序）</li>
 *   <li>校验渠道、金额</li>
 *   <li>payment_order 条件推进为成功</li>
 *   <li>orders 条件推进为已支付，并写入 paid_payment_no</li>
 *   <li>库存 locked -> sold（inventory_log 先做幂等）</li>
 *   <li>order_status_log + outbox_event</li>
 * </ol>
 *
 * <p>订单已被取消或已被另一笔支付结算时，钱已经到账，不能改订单状态，
 * 而是记支付成功 + 创建退款单 + 写 PAYMENT_LATE_OR_DUPLICATE 事件。
 */
@Service
public class PaymentCallbackService {

    private static final Logger log = LoggerFactory.getLogger(PaymentCallbackService.class);

    private static final int CALLBACK_PROCESSED = 1;

    @Resource
    private PayChannelRegistry payChannelRegistry;

    @Resource
    private PaymentCallbackLogMapper callbackLogMapper;

    @Resource
    private PaymentOrderMapper paymentOrderMapper;

    @Resource
    private OrdersMapper ordersMapper;

    @Resource
    private OrderItemMapper orderItemMapper;

    @Resource
    private OrderStatusLogMapper orderStatusLogMapper;

    @Resource
    private InventoryOperationMapper inventoryOperationMapper;

    @Resource
    private RefundService refundService;

    @Resource
    private OutboxAppender outboxAppender;

    /**
     * 处理渠道异步回调。方法返回即事务提交；抛异常则整体回滚，渠道可安全重试。
     */
    @Transactional
    public void handle(String channelCode, String rawBody, String signature) {
        PayChannel channel = payChannelRegistry.get(channelCode);
        PayChannel.CallbackMessage message = channel.verifyAndParse(rawBody, signature);
        validate(message);

        // 1. 幂等闸门必须是事务里的第一句。重复通知在这里返回 0。
        int inserted = callbackLogMapper.insertIgnore(
                message.notifyId(), message.paymentNo(), channel.code(), rawBody);
        if (inserted == 0) {
            Integer processStatus = callbackLogMapper.selectProcessStatus(channel.code(), message.notifyId());
            log.info("重复支付回调，直接返回成功：channel={}, notifyId={}, processStatus={}",
                    channel.code(), message.notifyId(), processStatus);
            return;
        }

        // 2. 锁顺序：orders -> payment_order。回调报文通常只有 paymentNo，先无锁查出 orderNo。
        String orderNo = paymentOrderMapper.selectOrderNoByPaymentNo(message.paymentNo());
        if (orderNo == null) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "PAYMENT_NOT_FOUND");
        }
        OrdersEntity order = ordersMapper.selectOne(
                Wrappers.<OrdersEntity>lambdaQuery()
                        .eq(OrdersEntity::getOrderNo, orderNo)
                        .last("FOR UPDATE"));
        if (order == null) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "ORDER_NOT_FOUND");
        }
        PaymentOrderEntity payment = paymentOrderMapper.selectForUpdateByPaymentNo(message.paymentNo());
        if (payment == null) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "PAYMENT_NOT_FOUND");
        }

        // 3. 渠道与金额校验。金额用 compareTo，不能用 equals（268.00 vs 268.0）。
        if (!payment.getChannel().equalsIgnoreCase(channel.code())) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "CHANNEL_MISMATCH");
        }
        if (message.amount() == null
                || payment.getAmount() == null
                || message.amount().compareTo(payment.getAmount()) != 0) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "PAYMENT_AMOUNT_MISMATCH");
        }

        if (Integer.valueOf(PaymentStatus.SUCCESS.code()).equals(payment.getStatus())) {
            markProcessed(channel.code(), message.notifyId());
            return;
        }

        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);

        // 4. 渠道明确告知失败：只关闭支付单，订单仍可重新发起支付。
        if (!message.success()) {
            int failed = paymentOrderMapper.markFailed(payment.getPaymentNo(), now);
            if (failed == 1) {
                outboxAppender.append("PAYMENT", payment.getPaymentNo(), "PAYMENT_FAILED",
                        paymentPayload(order, payment, message, null));
            }
            markProcessed(channel.code(), message.notifyId());
            return;
        }

        if (message.externalTradeNo() == null || message.externalTradeNo().isBlank()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "EXTERNAL_TRADE_NO_REQUIRED");
        }
        LocalDateTime paidAt = message.paidAt() != null ? message.paidAt() : now;

        // 5. 支付单条件推进：只有 status=0 才能变成 1。
        int claimed = paymentOrderMapper.markSuccess(
                payment.getPaymentNo(), message.externalTradeNo(), paidAt);
        if (claimed == 0) {
            markProcessed(channel.code(), message.notifyId());
            return;
        }

        // 6. 订单条件推进：只有待支付且尚未挂过结算支付单的订单才能变成已支付。
        int orderChanged = ordersMapper.update(null,
                Wrappers.<OrdersEntity>lambdaUpdate()
                        .set(OrdersEntity::getOrderStatus, OrderStatus.PAID.code())
                        .set(OrdersEntity::getPayTime, paidAt)
                        .set(OrdersEntity::getPaidPaymentNo, payment.getPaymentNo())
                        .setSql("version = version + 1")
                        .eq(OrdersEntity::getOrderNo, orderNo)
                        .eq(OrdersEntity::getOrderStatus, OrderStatus.PENDING_PAYMENT.code())
                        .isNull(OrdersEntity::getPaidPaymentNo));

        if (orderChanged == 0) {
            // 订单已取消（超时/用户取消）或已被另一笔支付结算：钱到账了，走退款。
            // 同一支付单的重复通知可能再次走到这里，退款金额上限保证不会重复退；
            // 只有真正创建了退款单才写事件。
            if (refundService.createLateOrDuplicateRefund(order, payment, now) != null) {
                outboxAppender.append("PAYMENT", payment.getPaymentNo(), "PAYMENT_LATE_OR_DUPLICATE",
                        paymentPayload(order, payment, message, paidAt));
            }
            markProcessed(channel.code(), message.notifyId());
            return;
        }

        // 7. 库存 locked -> sold。按 skuId 升序，降低并发死锁概率。
        List<OrderItemEntity> items = orderItemMapper.selectList(
                Wrappers.<OrderItemEntity>lambdaQuery()
                        .eq(OrderItemEntity::getOrderId, order.getId())
                        .orderByAsc(OrderItemEntity::getSkuId));
        if (items.isEmpty()) {
            throw new IllegalStateException("订单没有明细，无法推进库存: " + orderNo);
        }
        for (OrderItemEntity item : items) {
            int logInserted = inventoryOperationMapper.insertPayLogIfAbsent(
                    payment.getPaymentNo(), item.getSkuId(), item.getQuantity());
            if (logInserted == 0) {
                // 同一支付单 + SKU + change_type 已处理过，库存不能重复动
                continue;
            }
            int stockUpdated = inventoryOperationMapper.moveLockedToSold(
                    item.getSkuId(), item.getQuantity());
            if (stockUpdated == 0) {
                // 库存已被取消/关单流程释放，继续提交会造成账实不符，必须回滚并告警
                throw new IllegalStateException(
                        "库存不一致，支付回调回滚: paymentNo=" + payment.getPaymentNo()
                                + ", skuId=" + item.getSkuId());
            }
        }

        insertStatusLog(order);
        outboxAppender.append("PAYMENT", payment.getPaymentNo(), "PAYMENT_SUCCEEDED",
                paymentPayload(order, payment, message, paidAt));
        markProcessed(channel.code(), message.notifyId());
    }

    private void validate(PayChannel.CallbackMessage message) {
        if (message == null) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "INVALID_CALLBACK_BODY");
        }
        if (message.notifyId() == null || message.notifyId().isBlank()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "NOTIFY_ID_REQUIRED");
        }
        if (message.paymentNo() == null || message.paymentNo().isBlank()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "PAYMENT_NO_REQUIRED");
        }
    }

    private void markProcessed(String channel, String notifyId) {
        callbackLogMapper.markProcessed(channel, notifyId, CALLBACK_PROCESSED, null);
    }

    private void insertStatusLog(OrdersEntity order) {
        OrderStatusLogEntity statusLog = new OrderStatusLogEntity();
        statusLog.setOrderId(order.getId());
        statusLog.setFromStatus(OrderStatus.PENDING_PAYMENT.code());
        statusLog.setToStatus(OrderStatus.PAID.code());
        statusLog.setOperatorType(3);
        statusLog.setOperatorId(0L);
        statusLog.setReason("支付成功");
        orderStatusLogMapper.insert(statusLog);
    }

    private Map<String, Object> paymentPayload(OrdersEntity order,
                                               PaymentOrderEntity payment,
                                               PayChannel.CallbackMessage message,
                                               LocalDateTime paidAt) {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("orderNo", order.getOrderNo());
        payload.put("paymentNo", payment.getPaymentNo());
        payload.put("amount", payment.getAmount());
        payload.put("channel", payment.getChannel());
        payload.put("externalTradeNo", message.externalTradeNo());
        payload.put("paidAt", paidAt == null ? null : paidAt.toString());
        return payload;
    }
}
