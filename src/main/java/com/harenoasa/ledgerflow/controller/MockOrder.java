package com.harenoasa.ledgerflow.controller;

import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.ResponseBody;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class MockOrder {

    @PostMapping("/api/orders/{id}")
    public String mockOrder(@PathVariable Long id){

        return "return: " +  id;
    }


}
