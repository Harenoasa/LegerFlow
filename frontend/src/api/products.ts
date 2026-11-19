import type { ProductSummary } from '@/types'

import { request } from './http'

export function fetchProducts(limit = 100): Promise<ProductSummary[]> {
  return request<ProductSummary[]>(`/api/products?limit=${limit}`)
}
