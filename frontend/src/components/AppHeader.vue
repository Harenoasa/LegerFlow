<script setup lang="ts">
import { computed } from 'vue'
import { RouterLink, useRoute } from 'vue-router'

import { useCart } from '@/composables/useCart'

const route = useRoute()
const { count } = useCart()

const isHome = computed(() => route.name === 'home')
const isCart = computed(() => route.name === 'cart')
</script>

<template>
  <header class="site-header">
    <div class="container header-inner">
      <RouterLink class="brand" to="/" aria-label="LedgerFlow 商城首页">
        <span class="brand-mark">LF</span>
        <span class="brand-text">
          <strong>LedgerFlow</strong>
          <small>精选商城</small>
        </span>
      </RouterLink>

      <nav class="header-nav" aria-label="主导航">
        <RouterLink class="nav-link" :class="{ active: isHome }" to="/">首页</RouterLink>

        <RouterLink class="cart-link" :class="{ active: isCart }" to="/cart">
          <svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true">
            <path d="M3 4h2l2.2 10.2a1.5 1.5 0 0 0 1.47 1.18h8.72a1.5 1.5 0 0 0 1.46-1.14L20.5 7H6" stroke-linecap="round" stroke-linejoin="round" />
            <circle cx="9.5" cy="19.5" r="1.2" fill="currentColor" stroke="none" />
            <circle cx="17.5" cy="19.5" r="1.2" fill="currentColor" stroke="none" />
          </svg>
          <span>购物车</span>
          <span v-if="count > 0" class="cart-badge" aria-label="购物车商品数量">{{ count > 99 ? '99+' : count }}</span>
        </RouterLink>
      </nav>
    </div>
  </header>
</template>
