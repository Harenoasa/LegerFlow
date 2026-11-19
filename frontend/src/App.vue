<script setup lang="ts">
import { RouterView } from 'vue-router'

import AppHeader from '@/components/AppHeader.vue'
import AppToast from '@/components/AppToast.vue'
</script>

<template>
  <div class="app-shell">
    <AppHeader />

    <main class="app-main">
      <RouterView />
    </main>

    <footer class="app-footer">
      <div class="container footer-inner">
        <span>LedgerFlow · 高并发支付订单与记账平台</span>
        <span>前端演示 · 下单会真实锁定库存</span>
      </div>
    </footer>

    <AppToast />
  </div>
</template>
