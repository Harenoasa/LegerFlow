package com.ledgerflow.payment.channel;

import org.junit.jupiter.api.Test;
import org.springframework.web.server.ResponseStatusException;
import tools.jackson.databind.ObjectMapper;

import java.math.BigDecimal;
import java.time.LocalDateTime;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class MockPayChannelTest {

    private final MockPayChannel channel = new MockPayChannel(
            new ObjectMapper(), "test-secret", "http://localhost:5173/mock-pay");

    @Test
    void signsAndParsesCallback() {
        PayChannel.CallbackMessage message = new PayChannel.CallbackMessage(
                "notify-1", "PAY100", new BigDecimal("198.00"), true,
                "MOCK-TRADE-1", LocalDateTime.of(2026, 11, 11, 10, 0));

        String rawBody = channel.serialize(message);
        PayChannel.CallbackMessage parsed = channel.verifyAndParse(rawBody, channel.sign(rawBody));

        assertThat(parsed.notifyId()).isEqualTo("notify-1");
        assertThat(parsed.paymentNo()).isEqualTo("PAY100");
        assertThat(parsed.amount()).isEqualByComparingTo("198.00");
        assertThat(parsed.success()).isTrue();
        assertThat(parsed.externalTradeNo()).isEqualTo("MOCK-TRADE-1");
        assertThat(parsed.paidAt()).isEqualTo(LocalDateTime.of(2026, 11, 11, 10, 0));
    }

    @Test
    void rejectsInvalidSignature() {
        String rawBody = channel.serialize(new PayChannel.CallbackMessage(
                "notify-2", "PAY101", new BigDecimal("1.00"), true, "T-2", null));

        assertThatThrownBy(() -> channel.verifyAndParse(rawBody, "not-a-valid-signature"))
                .isInstanceOf(ResponseStatusException.class)
                .hasMessageContaining("INVALID_SIGNATURE");
    }

    @Test
    void rejectsMissingSignature() {
        String rawBody = channel.serialize(new PayChannel.CallbackMessage(
                "notify-3", "PAY102", new BigDecimal("1.00"), false, null, null));

        assertThatThrownBy(() -> channel.verifyAndParse(rawBody, null))
                .isInstanceOf(ResponseStatusException.class)
                .hasMessageContaining("SIGNATURE_REQUIRED");
    }
}
