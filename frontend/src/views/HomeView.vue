<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { RouterLink } from 'vue-router'

import { fetchProducts } from '@/api/products'
import EmptyState from '@/components/EmptyState.vue'
import ProductCard from '@/components/ProductCard.vue'
import { useCart } from '@/composables/useCart'
import { useToast } from '@/composables/useToast'
import type { ProductSummary } from '@/types'

const { addItem } = useCart()
const { push } = useToast()

const products = ref<ProductSummary[]>([])
const loading = ref(true)
const error = ref('')
const keyword = ref('')
const activeCategory = ref('全部')

const categories = computed(() => ['全部', ...new Set(products.value.map((item) => item.categoryName))])

const filtered = computed(() => {
  const word = keyword.value.trim().toLowerCase()

  return products.value.filter((product) => {
    const inCategory =
      activeCategory.value === '全部' || product.categoryName === activeCategory.value
    const matchesWord =
      word === '' ||
      `${product.title} ${product.subtitle} ${product.brand}`.toLowerCase().includes(word)
    return inCategory && matchesWord
  })
})

async function load(): Promise<void> {
  loading.value = true
  error.value = ''

  try {
    products.value = await fetchProducts(100)
  } catch {
    error.value = '商品加载失败，请确认后端已启动后再试。'
  } finally {
    loading.value = false
  }
}

function addToCart(product: ProductSummary): void {
  addItem({
    skuId: product.defaultSkuId,
    spuId: product.id,
    title: product.title,
    spec: product.defaultSkuSpec,
    price: product.defaultSkuPrice,
    quantity: 1,
    stock: product.defaultSkuStock
  })
  push(`已加入购物车：${product.title}`)
}

function scrollToProducts(): void {
  document.getElementById('product-grid')?.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

onMounted(load)
</script>

<template>
  <div class="home">
    <section class="hero container">
      <div class="hero-copy">
        <span class="eyebrow">LEDGERFLOW SELECT</span>
        <h1>把喜欢的好物，<br />放进今天的购物车。</h1>
        <p>
          从数据库实时读取商品与库存，下单即刻锁定库存。挑一件心仪好物，体验从选购到下单的完整流程。
        </p>

        <div class="hero-actions">
          <button class="primary-button" type="button" @click="scrollToProducts">立即选购</button>
          <RouterLink class="ghost-button" to="/cart">查看购物车</RouterLink>
        </div>

        <div class="hero-stats">
          <div>
            <strong>{{ products.length }}</strong>
            <span>在售商品</span>
          </div>
          <div>
            <strong>{{ Math.max(categories.length - 1, 0) }}</strong>
            <span>商品分类</span>
          </div>
          <div>
            <strong>10 min</strong>
            <span>支付时限</span>
          </div>
        </div>
      </div>

      <div class="hero-art" aria-hidden="true">
        <figure class="hero-photo hero-photo-a">
          <img src="/images/product-03.jpg" alt="" />
        </figure>
        <figure class="hero-photo hero-photo-b">
          <img src="/images/product-08.jpg" alt="" />
        </figure>
        <div class="hero-badge">
          <span>今日精选</span>
          <strong>10+ 好物</strong>
        </div>
      </div>
    </section>

    <section id="product-grid" class="catalog container">
      <div class="catalog-head">
        <div>
          <span class="eyebrow">CURATED FOR YOU</span>
          <h2>今日精选</h2>
        </div>

        <div class="catalog-tools">
          <label class="search-box">
            <svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true">
              <circle cx="11" cy="11" r="6.5" />
              <path d="m16 16 4 4" stroke-linecap="round" />
            </svg>
            <input v-model="keyword" type="search" placeholder="搜索商品、品牌" aria-label="搜索商品" />
          </label>
          <span class="result-count">{{ filtered.length }} 件</span>
        </div>
      </div>

      <div class="category-row">
        <button
          v-for="category in categories"
          :key="category"
          class="category-filter"
          :class="{ active: activeCategory === category }"
          type="button"
          @click="activeCategory = category"
        >
          {{ category }}
        </button>
      </div>

      <div v-if="loading" class="product-grid">
        <div v-for="n in 8" :key="n" class="product-card skeleton-card">
          <div class="skeleton-media"></div>
          <div class="skeleton-body">
            <span class="skeleton-line w-30"></span>
            <span class="skeleton-line w-80"></span>
            <span class="skeleton-line w-60"></span>
            <span class="skeleton-line w-40"></span>
          </div>
        </div>
      </div>

      <EmptyState
        v-else-if="error"
        title="商品加载失败"
        :description="error"
        action-label="重新加载"
        @action="load"
      />

      <EmptyState
        v-else-if="filtered.length === 0"
        title="暂时没有匹配的商品"
        description="换个关键词或分类试试，或者稍后再来看看。"
      />

      <TransitionGroup v-else name="card" tag="div" class="product-grid">
        <ProductCard
          v-for="product in filtered"
          :key="product.id"
          :product="product"
          @add="addToCart"
        />
      </TransitionGroup>
    </section>
  </div>
</template>
