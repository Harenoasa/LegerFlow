export interface ProductSummary {
  id: number
  spuNo: string
  title: string
  subtitle: string
  brand: string
  categoryId: number
  categoryName: string
  mainImage: string
  minPrice: number
  maxPrice: number
  originalPrice: number | null
  availableStock: number
  soldStock: number
  defaultSkuId: number
  defaultSkuSpec: string
  defaultSkuPrice: number
  defaultSkuStock: number
}

export interface CartItem {
  skuId: number
  spuId: number
  title: string
  spec: string
  price: number
  quantity: number
  stock: number
}

export interface OrderItemRequest {
  skuId: number
  quantity: number
}

export interface CreateOrderRequest {
  addressId: number
  items: OrderItemRequest[]
  expectedPayAmount: number
  source?: string
}

export interface CreateOrderResponse {
  orderNo: string
  orderStatus: string
}
