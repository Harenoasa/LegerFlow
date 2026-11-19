/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_ORDER_MAX_ATTEMPTS?: string
  readonly VITE_ORDER_BASE_DELAY_MS?: string
  readonly VITE_ORDER_MAX_DELAY_MS?: string
  readonly VITE_ORDER_REQUEST_TIMEOUT_MS?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}

