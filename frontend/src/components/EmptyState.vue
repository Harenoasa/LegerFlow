<script setup lang="ts">
defineProps<{
  title: string
  description?: string
  actionLabel?: string
}>()

const emit = defineEmits<{ (event: 'action'): void }>()
</script>

<template>
  <div class="empty-state">
    <div class="empty-orbit" aria-hidden="true"><span></span></div>
    <h3>{{
      }}</h3>
    <p v-if="description">{{ description }}</p>
    <button v-if="actionLabel" class="ghost-button" type="button" @click="emit('action')">
      {{ actionLabel }}
    </button>
  </div>
</template>
