<script setup lang="ts">
import { ref } from 'vue'
import { RouterLink, useRouter } from 'vue-router'

import CheckoutModal from '@/components/CheckoutModal.vue'
import EmptyState from '@/components/EmptyState.vue'
import { useCart } from '@/composables/useCart'
import { formatPrice } from '@/utils/format'
import { productImage } from '@/utils/productImage'

const router = useRouter()
const { items, count, total, updateQuantity, removeItem } = useCart()

const checkoutOpen = ref(false)

function goHome(): void {
  router.push('/')
}

function onQuantityInput(skuId: number, event: Event): void {
  const value = Number((event.target as HTMLInputElement).value)
  if (Number.isFinite(value)) updateQuantity(skuId, value)
}
</script>

<template>
  <div class="cart-page container">
    <header class="page-head">
      <div>
        <span class="eyebrow">YOUR CART</span>
        <h1>购物车</h1>
      </div>
      <RouterLink class="ghost-button" to="/">继续选购</RouterLink>
    </header>

    <EmptyState
      v-if="items.length === 0 && !checkoutOpen"
      title="购物车还是空的"
      description="去首页挑几件喜欢的商品吧，加入购物车后可以在这里统一结算。"
      action-label="去逛逛"
      @action="goHome"
    />

    <div v-else-if="items.length > 0" class="cart-layout">
      <section class="cart-lines" aria-label="购物车商品">
        <article v-for="item in items" :key="item.skuId" class="cart-line">
          <img class="cart-thumb" :src="productImage(item.spuId)" :alt="item.title" />

          <div class="cart-line-info">
            <h3>{{ item.title }}</h3>
            <p>{{ item.spec }}</p>
            <span class="cart-unit">单价 ¥{{ formatPrice(item.price) }}</span>
          </div>

          <div class="quantity-stepper">
            <button
              type="button"
              aria-label="减少数量"
              :disabled="item.quantity <= 1"
              @click="updateQuantity(item.skuId, item.quantity - 1)"
            >
              −
            </button>
            <input
              :value="item.quantity"
              type="number"
              min="1"
              :max="item.stock"
              aria-label="商品数量"
              @change="onQuantityInput(item.skuId, $event)"
            />
            <button
              type="button"
              aria-label="增加数量"
              :disabled="item.quantity >= item.stock"
              @click="updateQuantity(item.skuId, item.quantity + 1)"
            >
              +
            </button>
          </div>

          <div class="cart-line-total">¥{{ formatPrice(item.price * item.quantity) }}</div>

          <button class="remove-button" type="button" @click="removeItem(item.skuId)">移除</button>
        </article>
      </section>

      <aside class="cart-summary">
        <h2>订单摘要</h2>

        <div class="address-card">
          <span class="summary-label">收货地址</span>
          <strong>小鹿 · 13800000001</strong>
          <p>浙江省杭州市西湖区文三路 100 号 3 幢 501 室</p>
          <small>演示地址（addressId = 1）</small>
        </div>

        <dl class="summary-rows">
          <div>
            <dt>商品件数</dt>
            <dd>{{ count }} 件</dd>
          </div>
          <div>
            <dt>商品金额</dt>
            <dd>¥{{ formatPrice(total) }}</dd>
          </div>
          <div>
            <dt>运费</dt>
            <dd>免运费</dd>
          </div>
        </dl>

        <div class="summary-total">
          <span>应付合计</span>
          <strong>¥{{ formatPrice(total) }}</strong>
        </div>

        <button class="primary-button checkout-button" type="button" @click="checkoutOpen = true">
          去结算
        </button>
        <p class="summary-hint">点击结算即创建订单并锁定库存，请在 10 分钟内完成支付。</p>
      </aside>
    </div>

    <CheckoutModal v-model:open="checkoutOpen" :items="items" :total="total" />
  </div>
</template>
