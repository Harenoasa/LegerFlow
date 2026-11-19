<script setup lang="ts">
import { computed } from 'vue'

import type { ProductSummary } from '@/types'
import { formatInteger, formatPrice } from '@/utils/format'
import { productImage } from '@/utils/productImage'

const props = defineProps<{ product: ProductSummary }>()

const emit = defineEmits<{ (event: 'add', product: ProductSummary): void }>()

const soldOut = computed(() => props.product.defaultSkuStock <= 0)
const hasRange = computed(() => props.product.maxPrice > props.product.minPrice)
const hasDiscount = computed(
  () => props.product.originalPrice !== null && props.product.originalPrice > props.product.minPrice
)
const lowStock = computed(
  () => props.product.availableStock > 0 && props.product.availableStock < 10
)
</script>

<template>
  <article class="product-card">
    <div class="product-media">
      <img :src="productImage(product.id)" :alt="product.title" loading="lazy" />
      <span class="category-chip">{{ product.categoryName }}</span>
      <span v-if="soldOut" class="sold-out-chip">暂时缺货</span>
    </div>

    <div class="product-body">
      <div class="product-meta">
        <span class="brand-chip">{{ product.brand }}</span>
        <span class="sold-count">已售 {{ formatInteger(product.soldStock) }}</span>
      </div>

      <h3 class="product-title" :title="product.title">{{ product.title }}</h3>
      <p class="product-subtitle">{{ product.subtitle }}</p>

      <div class="product-price-row">
        <span class="price">
          <small>¥</small>{{ formatPrice(product.minPrice) }}<em v-if="hasRange">起</em>
        </span>
        <span v-if="hasDiscount" class="original-price">
          ¥{{ formatPrice(product.originalPrice ?? 0) }}
        </span>
      </div>

      <div class="product-footer">
        <span class="stock-note" :class="{ low: lowStock }">
          {{ product.availableStock > 0 ? `库存 ${formatInteger(product.availableStock)} 件` : '暂无库存' }}
        </span>

        <button class="add-button" type="button" :disabled="soldOut" @click="emit('add', product)">
          <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
            <path d="M12 5v14M5 12h14" stroke-linecap="round" />
          </svg>
          {{ soldOut ? '暂时缺货' : '加入购物车' }}
        </button>
      </div>
    </div>
  </article>
</template>
