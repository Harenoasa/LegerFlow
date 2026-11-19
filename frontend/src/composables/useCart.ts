import { computed, reactive, watch } from 'vue'

import type { CartItem } from '@/types'

const STORAGE_KEY = 'ledgerflow.cart.v1'

function isValidItem(value: unknown): value is CartItem {
  if (typeof value !== 'object' || value === null) return false
  const item = value as Record<string, unknown>
  return (
    typeof item.skuId === 'number' &&
    typeof item.spuId === 'number' &&
    typeof item.title === 'string' &&
    typeof item.spec === 'string' &&
    typeof item.price === 'number' &&
    typeof item.quantity === 'number' &&
    typeof item.stock === 'number'
  )
}

function loadCart(): CartItem[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return []
    const parsed: unknown = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    return parsed.filter(isValidItem)
  } catch {
    return []
  }
}

const state = reactive<{ items: CartItem[] }>({ items: loadCart() })

watch(
  state,
  () => {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(state.items))
    } catch {
      // 浏览器禁用存储时忽略，购物车仍在内存中可用
    }
  },
  { deep: true }
)

export function useCart() {
  const items = computed(() => state.items)

  const count = computed(() => state.items.reduce((sum, item) => sum + item.quantity, 0))

  const total = computed(() =>
    state.items.reduce((sum, item) => sum + item.price * item.quantity, 0)
  )

  function addItem(item: CartItem): void {
    if (item.stock <= 0 || item.quantity <= 0) return

    const existing = state.items.find((line) => line.skuId === item.skuId)
    if (existing) {
      existing.quantity = Math.min(existing.quantity + item.quantity, existing.stock)
      return
    }

    state.items.push({ ...item, quantity: Math.min(item.quantity, item.stock) })
  }

  function updateQuantity(skuId: number, quantity: number): void {
    const line = state.items.find((item) => item.skuId === skuId)
    if (!line) return
    line.quantity = Math.max(1, Math.min(Math.floor(quantity), line.stock))
  }

  function removeItem(skuId: number): void {
    const index = state.items.findIndex((item) => item.skuId === skuId)
    if (index >= 0) state.items.splice(index, 1)
  }

  function clear(): void {
    state.items.splice(0, state.items.length)
  }

  return { items, count, total, addItem, updateQuantity, removeItem, clear }
}
