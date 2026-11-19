export class HttpError extends Error {
  readonly status: number

  constructor(status: number, message = `HTTP ${status}`) {
    super(message)
    this.name = 'HttpError'
    this.status = status
  }
}

/**
 * 极简 fetch 封装：网络失败也统一成 HttpError(0)，页面只需按 status 映射文案。
 */
export async function request<T>(url: string, init: RequestInit = {}): Promise<T> {
  let response: Response
  try {
    response = await fetch(url, init)
  } catch {
    throw new HttpError(0, 'NETWORK_ERROR')
  }

  if (!response.ok) {
    throw new HttpError(response.status)
  }

  if (response.status === 204) {
    return undefined as T
  }

  return (await response.json()) as T
}
