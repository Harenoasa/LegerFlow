package com.harenoasa.ledgerflow.payment.channel;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ResponseStatusException;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.ObjectMapper;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.util.HexFormat;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * 本地模拟支付渠道。
 *
 * <p>用 HMAC-SHA256 模拟真实渠道的签名验证，回调报文形如：
 * <pre>{@code
 * {"notifyId":"N-xxx","paymentNo":"PAY123","amount":"198.00",
 *  "success":true,"externalTradeNo":"MOCK-TRADE-xxx","paidAt":"2026-11-11T10:00:00"}
 * }</pre>
 * 签名放在请求头 {@code X-Pay-Signature}，内容是原始报文的 HMAC-SHA256 十六进制串。
 */
@Component
public class MockPayChannel implements PayChannel {

    public static final String CODE = "MOCK";
    private static final String HMAC_ALGORITHM = "HmacSHA256";

    private final ObjectMapper objectMapper;
    private final String secret;
    private final String payBaseUrl;

    public MockPayChannel(ObjectMapper objectMapper,
                          @Value("${ledgerflow.payment.mock.secret:mock-pay-secret}") String secret,
                          @Value("${ledgerflow.payment.mock.pay-base-url:http://localhost:5173/mock-pay}") String payBaseUrl) {
        this.objectMapper = objectMapper;
        this.secret = secret;
        this.payBaseUrl = payBaseUrl;
    }

    @Override
    public String code() {
        return CODE;
    }

    @Override
    public PrepayResult prepay(PrepayCommand command) {
        return new PrepayResult(payBaseUrl + "/" + command.paymentNo());
    }

    @Override
    public CallbackMessage verifyAndParse(String rawBody, String signature) {
        if (signature == null || signature.isBlank()) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "SIGNATURE_REQUIRED");
        }
        byte[] expected = sign(rawBody).getBytes(StandardCharsets.UTF_8);
        byte[] actual = signature.trim().getBytes(StandardCharsets.UTF_8);
        if (!MessageDigest.isEqual(expected, actual)) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "INVALID_SIGNATURE");
        }
        try {
            MockCallbackBody body = objectMapper.readValue(rawBody, MockCallbackBody.class);
            return new CallbackMessage(
                    body.notifyId(),
                    body.paymentNo(),
                    body.amount(),
                    body.success(),
                    body.externalTradeNo(),
                    body.paidAt());
        } catch (JacksonException e) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "INVALID_CALLBACK_BODY");
        }
    }

    /** 仅供 dev profile 的 Mock 控制器生成回调报文。 */
    public String serialize(CallbackMessage message) {
        return objectMapper.writeValueAsString(new MockCallbackBody(
                message.notifyId(),
                message.paymentNo(),
                message.amount(),
                message.success(),
                message.externalTradeNo(),
                message.paidAt()));
    }

    /** 仅供 dev profile 的 Mock 控制器模拟渠道签名。 */
    public String sign(String rawBody) {
        try {
            Mac mac = Mac.getInstance(HMAC_ALGORITHM);
            mac.init(new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), HMAC_ALGORITHM));
            return HexFormat.of().formatHex(mac.doFinal(rawBody.getBytes(StandardCharsets.UTF_8)));
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException("无法初始化 HMAC-SHA256", e);
        }
    }

    @JsonIgnoreProperties(ignoreUnknown = true)
    private record MockCallbackBody(String notifyId,
                                    String paymentNo,
                                    java.math.BigDecimal amount,
                                    boolean success,
                                    String externalTradeNo,
                                    java.time.LocalDateTime paidAt) {
    }
}
