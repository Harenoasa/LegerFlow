<script setup lang="ts">
import { ref, watch } from 'vue'

import { HttpError } from '@/api/http'
import { createOrder } from '@/api/orders'
import { useCart } from '@/composables/useCart'
import { ORDER_RETRY_CONFIG } from '@/config/orderRetry'
import type { CartItem } from '@/types'
import { formatPrice } from '@/utils/format'

const props = defineProps<{
  open: boolean
  items: CartItem[]
  total: number
}>()

const emit = defineEmits<{ (event: 'update:open', value: boolean): void }>()

const { clear } = useCart()

type Phase = 'creating' | 'pending' | 'error'

const phase = ref<Phase>('creating')
const errorMessage = ref('')
const orderNo = ref('')
const recovered = ref(false)
let runId = 0
let clientToken = ''
let clientTokenFingerprint = ''

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, ms))
}

function makeClientToken(): string {
  return `web-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`
}

/** 购物车内容指纹：同一份订单才复用幂等键，改了商品/数量就开启新的结算会话 */
function orderFingerprint(): string {
  const lines = props.items
    .map((item) => `${item.skuId}x${item.quantity}`)
    .sort()
    .join('|')
  return `${lines}#${props.total.toFixed(2)}`
}
/**
 * 同一个结算会话复用同一个幂等键：失败后点击“再次查询”、或关掉弹窗重新结算，
 * 后端都会返回首次创建成功的订单号，不会重复下单。
 * 下单成功后购物车已清空，此时作废旧 token，下一次结算使用全新的键。
 */
function currentClientToken(): string {
  const fingerprint = orderFingerprint()
  if (!clientToken || clientTokenFingerprint !== fingerprint) {
    clientToken = makeClientToken()
    clientTokenFingerprint = fingerprint
  }
  return clientToken
}

function messageFor(error: unknown): string {
  if (error instanceof HttpError) {
    if (error.status === 0) return '网络连接失败，请确认后端服务已启动。'
    if (error.status === 404) return '收货地址不可用，请稍后重试。'
    if (error.status === 409) return '库存不足或价格已发生变化，请返回购物车刷新后重试。'
    if (error.status === 400) return '订单信息有误，请检查购物车后重试。'
  }
  return '下单失败，请稍后重试。'
}

const {
  maxAttempts: MAX_ATTEMPTS,
  baseDelayMs: BASE_DELAY,
  maxDelayMs: MAX_DELAY,
  requestTimeoutMs: REQUEST_TIMEOUT
} = ORDER_RETRY_CONFIG

type AttemptOutcome =
  | { kind: 'success'; orderNo: string }
  | { kind: 'retryable'; error: unknown }
  | { kind: 'fatal'; error: unknown }
  | { kind: 'stale' }

/** 只重试可能恢复的错误；400/404/409 这类业务错误直接结束 */
function isRetryable(error: unknown): boolean {
  if (!(error instanceof HttpError)) return false
  return (
    error.status === 0 ||
    error.status === 408 ||
    error.status === 429 ||
    error.status >= 500
  )
}

/** 指数退避 + 抖动：500ms → 1s → 2s → 4s，封顶 8s */
function backoffDelay(attempt: number): number {
  const ms = Math.min(MAX_DELAY, BASE_DELAY * 2 ** (attempt - 1))
  return ms * (0.5 + Math.random() * 0.5)
}

/** 保证 loading / error 面板至少展示一段时间，避免一闪而过 */
async function ensureMinElapsed(startedAt: number, ms: number): Promise<void> {
  const remaining = ms - (Date.now() - startedAt)
  if (remaining > 0) await delay(remaining)
}

/** 一次下单尝试：只负责把结果分类，不决定循环怎么走 */
async function attemptCreate(current: number): Promise<AttemptOutcome> {
  try {
    const response = await createOrder(
      {
        addressId: 1,
        items: props.items.map((item) => ({ skuId: item.skuId, quantity: item.quantity })),
        expectedPayAmount: Number(props.total.toFixed(2)),
        source: 'H5'
      },
      REQUEST_TIMEOUT,
      currentClientToken()
    )

    if (response.orderStatus !== 'PENDING_PAYMENT' || !response.orderNo) {
      return { kind: 'fatal', error: new Error('UNEXPECTED_ORDER_STATUS') }
    }
    return current === runId
      ? { kind: 'success', orderNo: response.orderNo }
      : { kind: 'stale' }
  } catch (error) {
    if (current !== runId) return { kind: 'stale' }
    return isRetryable(error)
      ? { kind: 'retryable', error }
      : { kind: 'fatal', error }
  }
}

async function submit(): Promise<void> {
  const current = ++runId
  const startedAt = Date.now()
  // 幂等键已存在且购物车未变化，说明这是失败后的再次查询
  const retrying = clientToken !== '' && clientTokenFingerprint === orderFingerprint()

  phase.value = 'creating'
  errorMessage.value = ''
  orderNo.value = ''
  recovered.value = false

  // 每个终态直接 return；只有“可重试”这一种结果会继续循环
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    const outcome = await attemptCreate(current)

    if (outcome.kind === 'stale') return

    if (outcome.kind === 'success') {
      await ensureMinElapsed(startedAt, 700)
      if (current !== runId) return

      orderNo.value = outcome.orderNo
      recovered.value = retrying
      clientToken = ''
      clientTokenFingerprint = ''
      clear()
      phase.value = 'pending'
      return
    }

    if (outcome.kind === 'fatal' || attempt === MAX_ATTEMPTS) {
      await ensureMinElapsed(startedAt, 500)
      if (current !== runId) return

      errorMessage.value = messageFor(outcome.error)
      phase.value = 'error'
      return
    }

    await delay(backoffDelay(attempt))
    if (current !== runId) return
  }
}

watch(
  () => props.open,
  (open) => {
    if (open) {
      void submit()
    } else {
      runId += 1
    }
  }
)

function requery(): void {
  if (phase.value === 'creating') return
  void submit()
}

function close(): void {
  if (phase.value === 'creating') return
  emit('update:open', false)
}
</script>

<template>
  <Teleport to="body">
    <Transition name="modal">
      <div v-if="open" class="modal-backdrop" @click.self="close">
        <section
          class="checkout-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="checkout-title"
          :aria-busy="phase === 'creating'"
        >
          <button
            v-if="phase !== 'creating'"
            class="modal-close"
            type="button"
            aria-label="关闭"
            @click="close"
          >
            ×
          </button>

          <Transition name="checkout-fade" mode="out-in">
            <div v-if="phase === 'creating'" key="creating" class="checkout-panel">
              <span class="spinner" aria-hidden="true"></span>
              <h2 id="checkout-title">订单创建中</h2>
              <p>正在为你校验价格并锁定库存，请稍候…</p>
              <div class="checkout-amount">应付 ¥{{ formatPrice(total) }}</div>
            </div>

            <div v-else-if="phase === 'pending'" key="pending" class="checkout-panel">
              <span class="success-mark" aria-hidden="true">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4">
                  <path d="m5 12.5 4.2 4.2L19 7" stroke-linecap="round" stroke-linejoin="round" />
                </svg>
              </span>
              <h2 id="checkout-title">正在跳转支付界面</h2>
              <p>
                {{ recovered ? '再次查询已确认订单，库存已为你锁定。' : '订单已创建，库存已为你锁定。' }}
              </p>
              <p class="checkout-note">支付页面即将上线，当前演示到此结束。</p>
              <button class="primary-button" type="button" @click="close">返回商城</button>
            </div>

            <div v-else key="error" class="checkout-panel">
              <span class="error-mark" aria-hidden="true">!</span>
              <h2 id="checkout-title">下单未完成</h2>
              <p>{{ errorMessage }}</p>
              <div class="checkout-actions">
                <button class="primary-button" type="button" @click="requery">再次查询订单</button>
                <button class="ghost-button" type="button" @click="close">返回购物车</button>
              </div>
              <p class="checkout-note">再次查询会复用本次结算的幂等键，不会重复下单。</p>
            </div>
          </Transition>

          <Transition name="order-reveal">
            <div
              v-if="phase === 'pending' && orderNo"
              class="order-reveal"
              role="status"
              aria-live="polite"
            >
              <div class="order-reveal-head">
                <span class="order-reveal-label">订单号</span>
                <span v-if="recovered" class="recovered-chip">再次查询成功</span>
              </div>
              <strong class="order-reveal-value">{{ orderNo }}</strong>
              <span class="order-reveal-hint">请保存订单号，以便查询支付状态与售后处理。</span>
            </div>
          </Transition>
        </section>
      </div>
    </Transition>
  </Teleport>
</template>
