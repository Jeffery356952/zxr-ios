import Foundation

/// 资源包格式与安卓离线版完全一致：
///   WebPack/web-static.pack  —— 所有文件按索引顺序裸拼接
///   WebPack/web-index.json   —— { "/cdn/x.png": {offset,size,mime}, ... }
struct PackEntry {
    let offset: Int64
    let size: Int
    let mime: String
}

final class PackStore {
    static let shared = PackStore()

    private var index: [String: PackEntry] = [:]
    private var fd: Int32 = -1
    private var packBytes: Int64 = 0
    private let lock = NSLock()
    private let loadQueue = DispatchQueue(label: "zxr.pack.load", qos: .userInitiated)

    private init() {}

    var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return fd >= 0
    }

    var entryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return index.count
    }

    var totalBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return packBytes
    }

    /// 后台加载索引，不阻塞启动；完成后回调到主线程
    func loadAsync(bundle: Bundle = .main, completion: @escaping (Bool) -> Void) {
        loadQueue.async {
            let ok = self.loadSync(bundle: bundle)
            DispatchQueue.main.async { completion(ok) }
        }
    }

    @discardableResult
    func loadSync(bundle: Bundle = .main) -> Bool {
        guard let indexURL = bundle.url(forResource: "web-index", withExtension: "json", subdirectory: "WebPack"),
              let packURL = bundle.url(forResource: "web-static", withExtension: "pack", subdirectory: "WebPack") else {
            NSLog("[ZXR] WebPack 未找到（可能是不含资源的调试构建）")
            return false
        }
        do {
            let started = Date()
            let data = try Data(contentsOf: indexURL, options: .mappedIfSafe)
            guard let raw = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                NSLog("[ZXR] web-index.json 解析失败")
                return false
            }
            var map: [String: PackEntry] = [:]
            map.reserveCapacity(raw.count)
            for (key, value) in raw {
                guard let item = value as? [String: Any],
                      let offset = (item["offset"] as? NSNumber)?.int64Value,
                      let size = (item["size"] as? NSNumber)?.intValue else { continue }
                let mime = (item["mime"] as? String) ?? "application/octet-stream"
                map[key] = PackEntry(offset: offset, size: size, mime: mime)
            }
            // 用 POSIX fd + pread：并发读不共享文件偏移，无需全局锁
            let opened = open(packURL.path, O_RDONLY)
            guard opened >= 0 else {
                NSLog("[ZXR] 资源包打开失败")
                return false
            }
            let size = lseek(opened, 0, SEEK_END)
            lock.lock()
            index = map
            if fd >= 0 { close(fd) }
            fd = opened
            packBytes = Int64(max(size, 0))
            lock.unlock()
            NSLog("[ZXR] 资源包就绪：\(map.count) 文件 / \(packBytes) 字节，用时 \(Int(Date().timeIntervalSince(started) * 1000))ms")
            return true
        } catch {
            NSLog("[ZXR] 资源包加载失败：\(error)")
            return false
        }
    }

    func entry(for path: String) -> PackEntry? {
        lock.lock(); defer { lock.unlock() }
        return index[path]
    }

    /// 从包的 offset 处读取一段内容（offset 相对文件起点）。线程安全：使用 pread。
    func read(path: String, offset: Int64, length: Int) -> Data? {
        let entry: PackEntry?
        let descriptor: Int32
        lock.lock()
        entry = index[path]
        descriptor = fd
        lock.unlock()

        guard let entry, descriptor >= 0 else { return nil }
        let start = entry.offset + offset
        let available = Int64(entry.size) - offset
        guard available > 0 else { return Data() }
        let count = Int(min(Int64(length), available))
        guard count > 0 else { return Data() }

        var buffer = [UInt8](repeating: 0, count: count)
        var total = 0
        while total < count {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.pread(descriptor, base.advanced(by: total), count - total, off_t(start) + off_t(total))
            }
            if n <= 0 {
                NSLog("[ZXR] 读包失败 \(path) @\(start + Int64(total))")
                return total > 0 ? Data(buffer[0..<total]) : nil
            }
            total += n
        }
        return Data(buffer)
    }

    deinit {
        if fd >= 0 { close(fd) }
    }
}
