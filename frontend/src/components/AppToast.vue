<script setup lang="ts">
import { useToast } from '@/composables/useToast'

const { toasts } = useToast()
</script>

<template>
  <Teleport to="body">
    <div class="toast-stack" aria-live="polite">
      <TransitionGroup name="toast">
        <div v-for="toast in toasts" :key="toast.id" class="toast" :class="toast.tone">
          {{ toast.message }}
        </div>
      </TransitionGroup>
    </div>
  </Teleport>
</template>
