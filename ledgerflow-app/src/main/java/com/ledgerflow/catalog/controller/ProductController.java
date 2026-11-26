package com.ledgerflow.catalog.controller;

import com.ledgerflow.catalog.dto.ProductSummaryDTO;
import com.ledgerflow.catalog.service.ProductQueryService;
import jakarta.annotation.Resource;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

@RestController
@RequestMapping("/api/products")
public class ProductController {

    @Resource
    private ProductQueryService productQueryService;

    /**
     * 首页商品列表。limit 默认 100，服务层夹在 1–100。
     */
    @GetMapping
    public List<ProductSummaryDTO> listProducts(@RequestParam(defaultValue = "100") int limit) {

        return productQueryService.listProducts(limit);
    }
}
