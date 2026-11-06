// very important, if you don't know what it is, don't touch it
// 非常重要，不懂代码不要动，这里可以解决80%的问题，也可以生产1000+的bug
const __pp_isBlobUrl = (url) =>
    typeof url === 'string' && url.startsWith('blob:')

const __pp_guessExtFromMime = (mime) => {
    const m = (mime || '').toLowerCase()
    const map = {
        'application/pdf': 'pdf',
        'image/png': 'png',
        'image/jpeg': 'jpg',
        'image/gif': 'gif',
        'image/webp': 'webp',
        'text/plain': 'txt',
        'application/json': 'json',
        'application/zip': 'zip',
        'application/octet-stream': 'bin',
    }
    return map[m] || ''
}

const __pp_readBlobAsBase64 = (blob) =>
    new Promise((resolve, reject) => {
        const reader = new FileReader()
        reader.onload = () => {
            const result = reader.result || ''
            const comma = result.indexOf(',')
            resolve(comma >= 0 ? result.slice(comma + 1) : result)
        }
        reader.onerror = () =>
            reject(reader.error || new Error('read blob failed'))
        reader.readAsDataURL(blob)
    })

const __pp_downloadBlobViaBridge = async (href, filename) => {
    const handler = window?.webkit?.messageHandlers?.blobDownload
    if (!handler) return false

    const id = `pp_${Date.now()}_${Math.random().toString(16).slice(2)}`
    try {
        // blob: 只能在页面上下文读取
        const res = await fetch(href)
        const blob = await res.blob()

        let name = filename || 'download'
        const ext = __pp_guessExtFromMime(blob.type)
        if (ext && !name.toLowerCase().endsWith(`.${ext}`)) {
            name = `${name}.${ext}`
        }

        // 2MB 分片，避免单次 postMessage 过大
        const chunkSize = 2 * 1024 * 1024
        const total = Math.max(1, Math.ceil(blob.size / chunkSize))

        handler.postMessage({
            action: 'start',
            id,
            filename: name,
            mimeType: blob.type || '',
            size: blob.size || 0,
            totalChunks: total,
        })

        for (let i = 0; i < total; i++) {
            const part = blob.slice(
                i * chunkSize,
                Math.min(blob.size, (i + 1) * chunkSize)
            )
            const base64 = await __pp_readBlobAsBase64(part)
            handler.postMessage({
                action: 'chunk',
                id,
                index: i,
                totalChunks: total,
                data: base64,
            })
        }

        handler.postMessage({ action: 'finish', id })
        return true
    } catch (err) {
        try {
            handler.postMessage({
                action: 'error',
                id,
                message: String(err && err.message ? err.message : err),
            })
        } catch (_) {}
        return false
    }
}

const hookClick = (e) => {
    const origin = e.target.closest('a')
    const isBaseTargetBlank = document.querySelector(
        'head base[target="_blank"]'
    )
    if (!origin || !origin.href) return

    // 1) 支持 blob: 下载：交给 iOS 侧保存，避免 Web 侧弹二次授权/下载失败
    if (__pp_isBlobUrl(origin.href)) {
        e.preventDefault()
        __pp_downloadBlobViaBridge(
            origin.href,
            origin.getAttribute('download') || origin.download
        ).then((ok) => {
            // bridge 不可用或失败：降级为原始行为
            if (!ok) location.href = origin.href
        })
        return
    }

    // 2) 原有逻辑：拦截 _blank / base[target=_blank]
    if (origin.target === '_blank' || isBaseTargetBlank) {
        e.preventDefault()
        location.href = origin.href
    }
}

window.open = function (url, target, features) {
    console.log('open', url, target, features)
    location.href = url
}

document.addEventListener('click', hookClick, { capture: true })
