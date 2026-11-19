import { reactive } from 'vue'

export type ToastTone = 'success' | 'error'

export interface ToastItem {
  id: number
  message: string
  tone: ToastTone
}

const toasts = reactive<ToastItem[]>([])
let sequence = 0

export function useToast() {
  function push(message: string, tone: ToastTone = 'success'): void {
    const id = ++sequence
    toasts.push({ id, message, tone })
    window.setTimeout(() => {
      const index = toasts.findIndex((toast) => toast.id === id)
      if (index >= 0) toasts.splice(index, 1)
    }, 2200)
  }

  return { toasts, push }
}
