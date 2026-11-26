package com.ledgerflow.order.controller;

import com.ledgerflow.order.dto.request.CreateOrderRequest;
import com.ledgerflow.order.dto.response.CreateOrderResponseDTO;
import com.ledgerflow.checkout.service.CreateService;
import jakarta.annotation.Resource;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/orders")
@Slf4j
public class CreateOrderController {

    @Resource
    private CreateService createService;

    /**
     * 下单。userId 暂由 {@code X-User-Id} 模拟登录态，接入认证后改为从 Token 获取。
     */
    @PostMapping
    public ResponseEntity<CreateOrderResponseDTO> createOrder(
            @RequestHeader(value = "X-User-Id", defaultValue = "1") Long userId,
            @RequestHeader(value = "Idempotency-Key")
            @NotBlank(message = "mesg cannot be null")
            String idempotencyKey,
            @Valid @RequestBody CreateOrderRequest request) {


        //Service
        String orderNo = createService.createOrder(userId, request,idempotencyKey);
        return ResponseEntity
                .status(HttpStatus.CREATED)
                .header(HttpHeaders.LOCATION, "/api/orders/" + orderNo)
                .body(CreateOrderResponseDTO.pending(orderNo));
    }
}
