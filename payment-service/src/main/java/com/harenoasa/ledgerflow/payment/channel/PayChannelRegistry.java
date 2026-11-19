package com.harenoasa.ledgerflow.payment.channel;

import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ResponseStatusException;

import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * 按渠道编码查找 {@link PayChannel} 实现。
 *
 * <p>Spring 会把所有 PayChannel bean 注入到构造器，新增渠道不需要改这里。
 */
@Component
public class PayChannelRegistry {

    private final Map<String, PayChannel> channels;

    public PayChannelRegistry(List<PayChannel> channelList) {
        Map<String, PayChannel> map = new LinkedHashMap<>();
        for (PayChannel channel : channelList) {
            String code = channel.code().toUpperCase(Locale.ROOT);
            PayChannel previous = map.putIfAbsent(code, channel);
            if (previous != null) {
                throw new IllegalStateException("重复的支付渠道编码: " + code);
            }
        }
        this.channels = Map.copyOf(map);
    }

    public PayChannel get(String code) {
        if (code == null || code.isBlank()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "CHANNEL_REQUIRED");
        }
        PayChannel channel = channels.get(code.toUpperCase(Locale.ROOT));
        if (channel == null) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "UNSUPPORTED_CHANNEL");
        }
        return channel;
    }

    public Collection<String> codes() {
        return channels.keySet();
    }
}
