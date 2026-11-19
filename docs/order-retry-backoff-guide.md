# 订单创建重试与退避实现指南

> 适用场景：`CheckoutModal` 提交订单后，遇到慢网、超时、断网或服务端临时错误时，使用同一幂等键进行退避重试。
>
> 相关文件：
>
> - `frontend/src/components/CheckoutModal.vue`
> - `frontend/src/api/orders.ts`
> - `frontend/src/api/http.ts`
> - `frontend/src/composables/useCart.ts`
> - `backend/.../service/CreateService.java`

## 一、“退避”不只是“等一会儿再试”

严格说，**退避（backoff）只负责“等多久”**；一个完整的重试策略还包括下面这些行为。实现时最好把它们拆成独立配置，不要写死在 `setTimeout` 里。

| 行为 | 作用 | 建议 |
| --- | --- | --- |
| 延迟递增 | 第一次快、后面慢，给服务端恢复时间 | `delay = min(maxDelay, baseDelay × 2^(attempt-1))` |
| 抖动 jitter | 防止多个客户端同一时刻一起重试 | 在延迟上乘一个随机系数，例如 `0.5 ~ 1.0` |
| 最大延迟 | 避免等太久 | 例如 8 秒封顶 |
| 最大次数 / 总时间预算 | 防止无限重试 | 例如最多 5 次，或总时长 ≤ 30 秒 |
| 错误分类 | 只重试“可能恢复”的错误 | 网络错误、超时、5xx、429 可重试；400/404/409 不重试 |
| 尊重服务端提示 | 服务端说多久后再来 | 429/503 如果带 `Retry-After`，优先用它 |
| 单飞 single-flight | 同一时间只允许一个请求在途 | 上一次没结束，不要发下一次 |
| 暂停 / 恢复 | 节省请求、避免无意义重试 | 断网时等 `online`；页面隐藏时暂停，回来再继续 |
| 取消与清理 | 关闭弹窗/卸载组件后不再重试 | `clearTimeout` + `AbortController.abort()` |
| 状态反馈 | 用户知道系统还在努力 | “订单确认中，第 2 次重试…”；失败后给手动按钮 |
| 幂等键不变 | 保证重试不会重复下单 | 整个结算意图共用一个 key |
| 预算重置 | 成功后清零；换购物车后换 key | 失败不重置次数，成功才重置 |

一个常见配置示例：

```text
baseDelay = 500ms
factor = 2
maxDelay = 8s
maxAttempts = 5
jitter = 0.5 ~ 1.0
总预算 ≈ 30s
```

实际间隔大约是：0.5s → 1s → 2s → 4s → 8s，再叠加随机抖动。

---

## 二、Vue 里需要掌握的方法

不需要学很多，够用即可。

### 1. 响应式状态

- `ref`：定义 `phase`、`orderNo`、`errorMessage`、`retryCount`
- `computed`：派生状态，例如“是否显示再次查询按钮”
- 模板里自动解包，`script` 里要用 `.value`

建议状态机：

```text
idle
  ↓ 提交
creating
  ├─ 2xx                 → pending
  ├─ 4xx 业务错误         → error
  └─ 超时/网络/5xx        → unknown
                              ↓ 退避重试
                           creating（同 key）
                              ├─ 成功 → pending
                              └─ 次数用尽 → error / 手动重试
```

### 2. 生命周期与清理

- `watch(() => props.open, ...)`：弹窗打开时开始，关闭时清理
- `onBeforeUnmount(...)`：组件卸载时清理定时器和请求
- 用 `let timer: ReturnType<typeof setTimeout> | undefined` 保存定时器
- 用 `let controller: AbortController | null` 保存当前请求

要点：

- 关闭弹窗、切换页面、重新发起请求前，都要 `clearTimeout` 并 `abort` 旧请求
- 不要只用 `Promise.race` 做超时，否则原请求还在跑，后面可能又回调 UI

### 3. 模板指令

- `v-if / v-else-if / v-else`：切换 creating / unknown / pending / error
- `@click`：再次查询、返回购物车
- `:disabled`：请求中禁用重复提交
- `v-model:open` 已经由 `CartView` 传入，不需要改父组件

### 4. 组件间通信

- 现有的 `defineProps` / `defineEmits` 够用
- 成功后才 `clear()` 购物车
- 幂等键建议由 `CheckoutModal` 自己管理，不要由父组件传

---

## 三、浏览器/平台工具

### 1. 超时与取消

- `AbortController`
- `fetch(url, { signal })`
- `AbortSignal.timeout(ms)`：一行实现客户端超时
- `AbortError`：主动取消时抛出的错误，注意不要当成网络失败去重试

现有 `frontend/src/api/http.ts` 会把所有 fetch 异常包装成 `HttpError(0)`，包括主动 abort。要实现“取消不重试”，需要在这里区分 `AbortError`，或者在调用方判断。

### 2. 定时器

- `setTimeout` / `clearTimeout`
- **不要用 `setInterval`**：请求慢时会叠加并发请求

### 3. 网络与页面状态

- `navigator.onLine`
- `window.addEventListener('online', ...)`
- `window.addEventListener('offline', ...)`
- `document.visibilityState`
- `document.addEventListener('visibilitychange', ...)`

记得在 `onBeforeUnmount` 或弹窗关闭时移除监听。

### 4. 幂等键持久化

- `sessionStorage`：刷新页面后还能找回本次结算的 key
- key 的取值建议仍然用现有的“购物车内容指纹”：
  - 购物车没变 → 复用 key
  - 商品/数量变化 → 新 key
  - 下单成功 → 清掉 key

### 5. 错误分类

现有 `HttpError` 的 `status` 已经够用：

| status | 类型 | 是否重试 |
| --- | --- | --- |
| `0` | 网络断开 / 超时 | 是 |
| `408`、`429` | 超时 / 限流 | 是，优先看 `Retry-After` |
| `5xx` | 服务端临时错误 | 是 |
| `400/401/403/404/409` | 业务错误 | 否 |

### 6. DevTools

- Network → Slow 3G / Offline：测试慢网和断网
- Application → Session Storage：检查幂等键
- Vue DevTools：观察 `phase`、`retryCount`
- Console：记录每次重试的 attempt、delay、错误类型

---

## 四、建议的模块划分

按现有项目结构，可以这样拆：

| 文件 | 职责 |
| --- | --- |
| `frontend/src/utils/retry.ts` | 纯函数：`computeDelay()`、`isRetryable()`、`jitter()` |
| `frontend/src/api/orders.ts` | `createOrder` 增加 `signal` / 超时参数 |
| `frontend/src/api/http.ts` | 区分 `AbortError`，支持 `signal` |
| `frontend/src/components/CheckoutModal.vue` | 状态机、定时器、UI |
| `frontend/src/composables/useCheckoutRetry.ts`（可选） | 如果逻辑变多，再抽成 composable |

先不要引入 `axios-retry`、`p-retry` 这类库。这个场景自己实现一遍，才能真正理解退避、抖动、取消和幂等。

---

## 五、建议的实现顺序

1. **先做状态机**：creating / unknown / pending / error，不加重试
2. **加错误分类**：哪些错误进入 unknown，哪些直接 error
3. **加幂等键持久化 + 指纹判断**
4. **加单次延迟重试**：固定 1 秒，确认同一 key 能找回订单
5. **改成指数退避 + 抖动 + 最大次数**
6. **加取消与清理**：关闭弹窗、`onBeforeUnmount`
7. **加断网/页面隐藏的暂停恢复**
8. **加迟到响应保护**：
   - 旧错误忽略
   - 旧成功可以接受
   - 一旦成功不再回退
9. **最后测慢网、超时、刷新、重复点击**

---

## 六、测试用例

至少覆盖这些：

1. 正常快速成功
2. 慢网成功，但没超过客户端超时
3. 客户端超时，服务端其实已创建 → 重试返回原订单
4. 断网 → 恢复网络 → 自动重试
5. 4xx 业务错误 → 不自动重试
6. 请求中途关闭弹窗 → 定时器清理、不再更新 UI
7. 重试成功后又收到旧错误响应 → 成功状态不被覆盖
8. 刷新页面后 key 还在 → 继续查询拿到同一订单
9. 快速重复点击结算 → 只有一个在途请求

---

## 七、容易踩的坑

- 不要每次重试生成新 key
- 不要在 `creating` / `unknown` 时允许用户重新提交新结算
- 不要在成功前清空购物车
- 不要用 `setInterval`
- 不要把 `AbortError` 当成网络失败去无限重试
- 不要让旧请求的错误覆盖已经成功的状态
- 不要只在前端做幂等，后端 `CreateService` 的“先查后插”也要改成唯一键 + `DuplicateKeyException` 兜底，否则并发重试仍可能 500 或重复下单

---

## 八、起步方式

可以先从“状态机 + 固定 1 秒重试”开始写，跑通后再换成指数退避。遇到具体卡点再针对性 review。
