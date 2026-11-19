const IMAGE_COUNT = 20

/**
 * 按 SPU ID 稳定映射到 20 张本地图片：随机感足够，且首页与购物车始终一致。
 */
export function productImage(spuId: number): string {
  const index = ((Math.imul(spuId, 2654435761) >>> 0) % IMAGE_COUNT) + 1
  return `${import.meta.env.BASE_URL}images/product-${String(index).padStart(2, '0')}.jpg`
}
