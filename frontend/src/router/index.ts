import { createRouter, createWebHistory } from 'vue-router'

import HomeView from '@/views/HomeView.vue'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    {
      path: '/',
      name: 'home',
      component: HomeView
    },
    {
      path: '/cart',
      name: 'cart',
      component: () => import('@/views/CartView.vue')
    },
    {
      path: '/:pathMatch(.*)*',
      redirect: '/'
    }
  ],
  scrollBehavior: () => ({ top: 0 })
})

export default router
