/**
 * 下单重试配置。
 *
 * <p>可通过 frontend/.env 中的 VITE_ORDER_* 覆盖；修改 .env 后需要重启 Vite dev server。
 */

function positiveInt(value: string | undefined, fallback: number): number {
  const parsed = Number(value)
  return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : fallback
}

export const ORDER_RETRY_CONFIG = {
  maxAttempts: positiveInt(import.meta.env.VITE_ORDER_MAX_ATTEMPTS, 5),
  baseDelayMs: positiveInt(import.meta.env.VITE_ORDER_BASE_DELAY_MS, 500),
  maxDelayMs: positiveInt(import.meta.env.VITE_ORDER_MAX_DELAY_MS, 8000),
  requestTimeoutMs: positiveInt(import.meta.env.VITE_ORDER_REQUEST_TIMEOUT_MS, 5000)
} as const
