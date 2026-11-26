package com.ledgerflow.checkout.service;

import com.baomidou.mybatisplus.core.conditions.query.LambdaQueryWrapper;
import com.baomidou.mybatisplus.core.conditions.update.LambdaUpdateWrapper;
import com.baomidou.mybatisplus.core.toolkit.Wrappers;
import com.ledgerflow.common.OrderNoGenerator;
import com.ledgerflow.common.OrderStatus;
import com.ledgerflow.order.dto.request.CreateOrderItemRequest;
import com.ledgerflow.order.dto.request.CreateOrderRequest;
import com.ledgerflow.inventory.entity.InventoryEntity;
import com.ledgerflow.inventory.entity.InventoryLogEntity;
import com.ledgerflow.order.entity.OrderItemEntity;
import com.ledgerflow.order.entity.OrderStatusLogEntity;
import com.ledgerflow.order.entity.OrdersEntity;
import com.ledgerflow.catalog.entity.ProductSkuEntity;
import com.ledgerflow.catalog.entity.ProductSpuEntity;
import com.ledgerflow.order.entity.UserAddressEntity;
import com.ledgerflow.inventory.mapper.InventoryLogMapper;
import com.ledgerflow.inventory.mapper.InventoryMapper;
import com.ledgerflow.order.mapper.OrderItemMapper;
import com.ledgerflow.order.mapper.OrderStatusLogMapper;
import com.ledgerflow.order.mapper.OrdersMapper;
import com.ledgerflow.catalog.mapper.ProductSkuMapper;
import com.ledgerflow.catalog.mapper.ProductSpuMapper;
import com.ledgerflow.order.mapper.UserAddressMapper;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.server.ResponseStatusException;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 创建订单的简单实现：校验地址 / SKU、锁定库存、写订单及周边流水。
 *
 * <p>暂未实现：幂等键、优惠券、运费、outbox 事件、购物车清理。
 */
@Service
public class CreateService {

    @Value("${ledgerflow.timeout.payment}")
    private int PAY_TIMEOUT_MINUTES;

    public CreateService(UserAddressMapper userAddressMapper, ProductSkuMapper productSkuMapper, ProductSpuMapper productSpuMapper, InventoryMapper inventoryMapper, InventoryLogMapper inventoryLogMapper, OrdersMapper ordersMapper, OrderItemMapper orderItemMapper, OrderStatusLogMapper orderStatusLogMapper, OrderNoGenerator orderNoGenerator) {
        this.userAddressMapper = userAddressMapper;
        this.productSkuMapper = productSkuMapper;
        this.productSpuMapper = productSpuMapper;
        this.inventoryMapper = inventoryMapper;
        this.inventoryLogMapper = inventoryLogMapper;
        this.ordersMapper = ordersMapper;
        this.orderItemMapper = orderItemMapper;
        this.orderStatusLogMapper = orderStatusLogMapper;
        this.orderNoGenerator = orderNoGenerator;
    }
    private final UserAddressMapper userAddressMapper;
    private final ProductSkuMapper productSkuMapper;
    private final ProductSpuMapper productSpuMapper;
    private final InventoryMapper inventoryMapper;
    private final InventoryLogMapper inventoryLogMapper;
    private final OrdersMapper ordersMapper;
    private final OrderItemMapper orderItemMapper;
    private final OrderStatusLogMapper orderStatusLogMapper;
    private final OrderNoGenerator orderNoGenerator;

    /**
     * 创建订单并返回订单编号。
     *
     * @param userId  当前登录用户 ID
     * @param request 下单请求
     */
    @Transactional
    public String createOrder(Long userId, CreateOrderRequest request,String idempotencyKey) {

        //幂等性检查
        IdempotencyResult result = idempotencyValidation(idempotencyKey);
        if (!result.validity) {
            //已存在幂等键，返回订单编号
            return ordersMapper.selectOne(new LambdaQueryWrapper<OrdersEntity>().select(OrdersEntity::getOrderNo).eq(OrdersEntity::getId,result.incrId)).getOrderNo();
        };

        AddressSnapshot address = loadAddress(userId, request.getAddressId());
        String orderNo = orderNoGenerator.next();
        // 提前落订单入库是为了节省db查询频率。在这里修改方法签名，减去totalAmount ，payAmount，换到更新操作里放入
        // incrId: 自增主键id
        long incrId = insertOrder(orderNo, userId, address, request.getBuyerRemark(),idempotencyKey);
        // 同一 SKU 可能出现在多行，合并数量后再查询/锁库存，
        // 否则同单会重复写 inventory_log，触发 (biz_type, biz_no, sku_id, change_type) 唯一键冲突
        Map<Long, Integer> quantityBySku = new LinkedHashMap<>();
        for (CreateOrderItemRequest item : request.getItems()) {
            quantityBySku.merge(item.getSkuId(), item.getQuantity(), Integer::sum);
        }

        List<OrderLine> lines = new ArrayList<>();
        for (Map.Entry<Long, Integer> entry : quantityBySku.entrySet()) {
            lines.add(buildOrderLine(entry.getKey(), entry.getValue()));
        }

        BigDecimal totalAmount = lines.stream()
                .map(OrderLine::itemAmount)
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal payAmount = totalAmount; // 暂不计算优惠与运费
        updateOrder(totalAmount, payAmount, incrId);
        if (request.getExpectedPayAmount() != null
                && request.getExpectedPayAmount().compareTo(payAmount) != 0) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "PRICE_CHANGED");
        }
        // 按 skuId 升序锁库存，降低并发下单时的死锁概率
        lines.sort(Comparator.comparingLong(OrderLine::skuId));

        for (OrderLine line : lines) {
            lockStock(orderNo, line.skuId(), line.quantity());
        }

        for (OrderLine line : lines) {
            insertOrderItem(incrId, line);
        }
        insertStatusLog(incrId, userId);
        return orderNo;
    }

    private record IdempotencyResult(boolean validity, Long incrId){}

    private AddressSnapshot loadAddress(Long userId, Long addressId) {
        UserAddressEntity address = userAddressMapper.selectOne(
                Wrappers.<UserAddressEntity>lambdaQuery()
                        .eq(UserAddressEntity::getId, addressId)
                        .eq(UserAddressEntity::getUserId, userId)
                        .isNull(UserAddressEntity::getDeletedAt)
                        .select(UserAddressEntity::getReceiverName,
                                UserAddressEntity::getReceiverPhone,
                                UserAddressEntity::getProvince,
                                UserAddressEntity::getCity,
                                UserAddressEntity::getDistrict,
                                UserAddressEntity::getDetailAddress));
        if (address == null) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "ADDRESS_NOT_FOUND");
        }
        return new AddressSnapshot(
                address.getReceiverName(),
                address.getReceiverPhone(),
                address.getProvince(),
                address.getCity(),
                address.getDistrict(),
                address.getDetailAddress());
    }

    private OrderLine buildOrderLine(long skuId, int quantity) {
        ProductSkuEntity sku = productSkuMapper.selectOne(
                Wrappers.<ProductSkuEntity>lambdaQuery()
                        .eq(ProductSkuEntity::getId, skuId)
                        .eq(ProductSkuEntity::getStatus, 1)
                        .isNull(ProductSkuEntity::getDeletedAt)
                        .select(ProductSkuEntity::getSpuId,
                                ProductSkuEntity::getPrice,
                                ProductSkuEntity::getSpecSummary));
        if (sku == null) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "SKU_OFF_SHELF");
        }

        ProductSpuEntity spu = productSpuMapper.selectOne(
                Wrappers.<ProductSpuEntity>lambdaQuery()
                        .eq(ProductSpuEntity::getId, sku.getSpuId())
                        .eq(ProductSpuEntity::getStatus, 1)
                        .isNull(ProductSpuEntity::getDeletedAt)
                        .select(ProductSpuEntity::getTitle,
                                ProductSpuEntity::getMainImageUrl));
        if (spu == null) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "SKU_OFF_SHELF");
        }

        BigDecimal unitPrice = sku.getPrice();
        BigDecimal itemAmount = unitPrice.multiply(BigDecimal.valueOf(quantity));
        return new OrderLine(
                skuId,
                sku.getSpuId(),
                spu.getTitle(),
                sku.getSpecSummary(),
                spu.getMainImageUrl(),
                unitPrice,
                quantity,
                itemAmount,
                itemAmount);
    }

    private void lockStock(String orderNo, long skuId, int quantity) {
        InventoryEntity inventory = inventoryMapper.selectOne(
                Wrappers.<InventoryEntity>lambdaQuery()
                        .eq(InventoryEntity::getSkuId, skuId)
                        .select(InventoryEntity::getAvailableStock)
                        .last("FOR UPDATE"));
        if (inventory == null) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "OUT_OF_STOCK");
        }
        int before = inventory.getAvailableStock();

        LambdaUpdateWrapper<InventoryEntity> update = Wrappers.<InventoryEntity>lambdaUpdate()
                .eq(InventoryEntity::getSkuId, skuId)
                .ge(InventoryEntity::getAvailableStock, quantity)
                .setSql("available_stock = available_stock - " + quantity
                        + ", locked_stock = locked_stock + " + quantity
                        + ", version = version + 1");
        int updated = inventoryMapper.update(null, update);
        if (updated == 0) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "OUT_OF_STOCK");
        }

        InventoryLogEntity log = new InventoryLogEntity();
        log.setSkuId(skuId);
        log.setChangeType(1);
        log.setChangeQty(quantity);
        log.setBeforeAvailable(before);
        log.setAfterAvailable(before - quantity);
        log.setBizType("ORDER_CREATE");
        log.setBizNo(orderNo);
        log.setRemark("下单锁定库存");
        inventoryLogMapper.insert(log);
    }

    private IdempotencyResult idempotencyValidation(String idempotencyKey) {
        OrdersEntity order = ordersMapper.selectOne(
                new LambdaQueryWrapper<OrdersEntity>()
                        .select(OrdersEntity::getId)
                        .eq(OrdersEntity::getClientToken, idempotencyKey));
        if (order == null) return new IdempotencyResult(true, null);
        return new IdempotencyResult(false, order.getId());

    }

    private long insertOrder(String orderNo, Long userId, AddressSnapshot address,
                             String buyerRemark,String idempotencyKey) {
        LocalDateTime expireAt = LocalDateTime.now(ZoneOffset.UTC).plusMinutes(PAY_TIMEOUT_MINUTES);

        OrdersEntity order = new OrdersEntity();
        //初创数据，把无需计算的字段先存入db
        //设置token
        order.setClientToken(idempotencyKey);
        order.setOrderNo(orderNo);
        order.setUserId(userId);
        order.setOrderStatus(OrderStatus.PENDING_PAYMENT.code());
        order.setDiscountAmount(BigDecimal.ZERO);
        order.setFreightAmount(BigDecimal.ZERO);
        order.setReceiverName(address.receiverName());
        order.setReceiverPhone(address.receiverPhone());
        order.setReceiverProvince(address.province());
        order.setReceiverCity(address.city());
        order.setReceiverDistrict(address.district());
        order.setReceiverDetail(address.detailAddress());
        order.setBuyerRemark(buyerRemark == null ? "" : buyerRemark);
        order.setExpireAt(expireAt);
        ordersMapper.insert(order);

        Long orderId = order.getId();
        if (orderId == null) {
            throw new IllegalStateException("获取订单 ID 失败");
        }
        return orderId;
    }

    private void updateOrder(BigDecimal totalAmount, BigDecimal payAmount, Long orderId) {
        int rows = ordersMapper.update(null,
                new LambdaUpdateWrapper<OrdersEntity>()
                        .set(OrdersEntity::getTotalAmount, totalAmount)
                        .set(OrdersEntity::getPayAmount, payAmount)
                        .eq(OrdersEntity::getId, orderId));
        if  (rows == 0) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "update 0 row");
        }
    }

    private void insertOrderItem(long orderId, OrderLine line) {
        OrderItemEntity item = new OrderItemEntity();
        item.setOrderId(orderId);
        item.setSpuId(line.spuId());
        item.setSkuId(line.skuId());
        item.setProductName(line.productName());
        item.setSkuSpec(line.skuSpec());
        item.setImageUrl(line.imageUrl());
        item.setUnitPrice(line.unitPrice());
        item.setQuantity(line.quantity());
        item.setItemAmount(line.itemAmount());
        item.setDiscountAmount(BigDecimal.ZERO);
        item.setPayAmount(line.payAmount());
        orderItemMapper.insert(item);
    }

    private void insertStatusLog(long orderId, long userId) {
        OrderStatusLogEntity log = new OrderStatusLogEntity();
        log.setOrderId(orderId);
        log.setToStatus(OrderStatus.PENDING_PAYMENT.code());
        log.setOperatorType(1);
        log.setOperatorId(userId);
        log.setReason("创建订单");
        orderStatusLogMapper.insert(log);
    }

    private record AddressSnapshot(String receiverName, String receiverPhone, String province,
                                   String city, String district, String detailAddress) {
    }

    private record OrderLine(long skuId, long spuId, String productName, String skuSpec,
                             String imageUrl, BigDecimal unitPrice, int quantity,
                             BigDecimal itemAmount, BigDecimal payAmount) {
    }
}
