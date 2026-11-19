import type { CreateOrderRequest, CreateOrderResponse } from '@/types'

import { request } from './http'

export function createOrder(
  payload: CreateOrderRequest,
  timeoutMs: number,
  idempotencyKey: string
): Promise<CreateOrderResponse> {
  return request<CreateOrderResponse>('/api/orders', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Idempotency-Key': idempotencyKey,
      'X-User-Id': '1'
    },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(timeoutMs)
  })
}
