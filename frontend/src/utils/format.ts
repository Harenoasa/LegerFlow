const priceFormatter = new Intl.NumberFormat('zh-CN', {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2
})

const integerFormatter = new Intl.NumberFormat('zh-CN')

export function formatPrice(value: number): string {
  return priceFormatter.format(Number.isFinite(value) ? value : 0)
}

export function formatInteger(value: number): string {
  return integerFormatter.format(Number.isFinite(value) ? value : 0)
}
