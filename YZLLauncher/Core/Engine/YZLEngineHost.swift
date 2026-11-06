import Foundation
import UIKit
import ObjectiveC
import dlfcn

/// M2-b 运行时桥：在 Amethyst fork 进程内，由 YZL UI（YZLUI.framework）
/// 驱动引擎启动。
///
/// 设计前提（见 docs/M2B-ENGINE.md）：
/// - fork 的主二进制里才有 `launchJVM` 符号——纯外壳构建里 dlsym 找不到，
///   本桥如实报 `notIntegrated`，不会假装可用；
/// - 启动契约（mainClass / classpath / gameArgs）通过 `YZL_LAUNCH_PLAN.json`
///   交给 fork 内打了补丁的 `PojavLauncher` Java 主类；
/// - 游戏画面由 fork 的 `SurfaceViewController` 承载，这里用运行时类查找呈现，
///   编译期不依赖任何 Amethyst 源码——纯外壳构建保持全绿。
struct YZLEngineHost: LauncherEngine {
    typealias JavaHomeProvider = () -> URL?
    typealias SymbolResolver = (String) -> UnsafeMutableRawPointer?

    let name = "Amethyst 引擎（fork，YZL UI 注入）"

    private let payload: EnginePayloadLocator.Payload
    private let javaHomeProvider: JavaHomeProvider
    private let probe: JITProbe.Probe
    private let resolveSymbol: SymbolResolver
    private let classLookup: (String) -> AnyClass?

    init(payload: EnginePayloadLocator.Payload? = nil,
         javaHome: @escaping JavaHomeProvider = { RuntimeLocator.javaHome() },
         probe: @escaping JITProbe.Probe = JITProbe.systemProbe,
         resolveSymbol: @escaping SymbolResolver = { symbol in
             // RTLD_DEFAULT 在 Apple 平台是空指针；dlsym(nil, ...) 即全局查找。
             dlsym(nil, symbol)
         },
         classLookup: @escaping (String) -> AnyClass? = { NSClassFromString($0) }) {
        self.payload = payload ?? EnginePayloadLocator.scan()
        self.javaHomeProvider = javaHome
        self.probe = probe
        self.resolveSymbol = resolveSymbol
        self.classLookup = classLookup
    }

    /// fork 进程内 dlsym 能命中 `launchJVM` 才算桥接就绪。
    var isRuntimeLinked: Bool {
        resolveSymbol("launchJVM") != nil
    }

    var isAvailable: Bool {
        payload.isLaunchable && isRuntimeLinked
    }

    func launch(_ plan: LaunchPlan) async throws {
        guard let javaHome = javaHomeProvider() else {
            throw EngineError.runtimeMissing
        }
        guard JITProbe.detect(using: probe) == .enabled else {
            throw EngineError.jitDisabled
        }
        guard payload.isLaunchable else {
            throw EngineLaunchFailure.payloadMissing(payload.summary)
        }
        guard let launchSymbol = resolveSymbol("launchJVM") else {
            throw EngineError.notIntegrated
        }

        // 1. 写启动契约（含令牌，只落应用沙箱内的 YZLEngineHome）。
        let accessToken = Self.accessTokenFromPlan(plan)
        guard !accessToken.isEmpty else {
            throw EngineError.launchFailed("启动计划缺少访问令牌，无法写入启动契约。")
        }
        let home = EngineLaunchContract.homeDirectory
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let document = try EngineLaunchContract.document(from: plan, accessToken: accessToken)
        try EngineLaunchContract.write(document, homeDirectory: home)

        // 2. 环境变量：AME_HOME（fork 主目录约定）与契约路径。
        setenv("AME_HOME", home.path, 1)
        setenv("YZL_LAUNCH_PLAN", home.appendingPathComponent("yzl-launch-plan.json").path, 1)
        setenv("GAME_DIR", plan.gameDirectory.path, 1)
        setenv("JAVA_HOME", javaHome.path, 1)

        // 3. launchJVM(username, launchTarget, width, height, minVersion)。
        //    launchTarget 走字典（profile 模式）；fork 的 PojavLauncher 补丁读
        //    YZL_LAUNCH_PLAN，这里只带版本 id 与空 jvm_processed。
        //    前两个参数都是 ObjC 对象指针（NSString* / NSDictionary*），
        //    用 Unmanaged 透传（launchJVM 不越过本次调用持有它们）；
        //    ObjC 运行时触碰 UI 状态，固定在主线程执行。
        typealias LaunchJVM = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, Int32, Int32, Int32) -> Int32
        let launch = unsafeBitCast(launchSymbol, to: LaunchJVM.self)
        let username = plan.accountName
        let minJava = Int32(document.javaMajor)

        let exitCode: Int32 = await MainActor.run {
            let nsName = username as NSString
            let target: NSDictionary = [
                "id": plan.version.id,
                "arguments": ["jvm_processed": NSArray()]
            ]
            return launch(
                Unmanaged.passUnretained(nsName).toOpaque(),
                Unmanaged.passUnretained(target).toOpaque(),
                0, 0, minJava
            )
        }

        // 4. 契约文件含令牌，启动流程已交接即删。
        EngineLaunchContract.remove(homeDirectory: home)

        if exitCode != 0 {
            throw EngineLaunchFailure.engineExit(exitCode)
        }
    }

    // MARK: - 游戏画面

    /// fork 的 SurfaceViewController 是 ObjC 类，编译期不引用；
    /// 运行时 objc_getClass + init 呈现。找不到则跳过（JVM 照常启动，
    /// 只是无画面——用于引擎链路的头级验证）。fork 首编时按
    /// SurfaceViewController.h 的实际初始化签名核对（见 fork 补丁 3 TODO）。
    @MainActor
    private func presentGameSurface() {
        guard let surfaceClass = classLookup("SurfaceViewController") as? UIViewController.Type else {
            return
        }
        let surface = surfaceClass.init()
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        surface.modalPresentationStyle = .fullScreen
        keyWindow?.rootViewController?.present(surface, animated: false)
    }

    // MARK: - 令牌传递

    /// LaunchPlan 不携带独立令牌字段（游戏参数里已内联 --accessToken），
    /// 契约需要独立令牌值：从游戏参数里取回，避免第二条持久化路径。
    static func accessTokenFromPlan(_ plan: LaunchPlan) -> String {
        let arguments = plan.gameArguments
        guard let index = arguments.firstIndex(of: "--accessToken"),
              index + 1 < arguments.count else {
            return plan.gameArguments.contains("offline") ? "offline" : ""
        }
        return arguments[index + 1]
    }
}

/// M2-b 桥专属错误：比 EngineError.notIntegrated 更细的失败定位。
enum EngineLaunchFailure: LocalizedError, Equatable {
    case payloadMissing(String)
    case engineExit(Int32)

    var errorDescription: String? {
        switch self {
        case .payloadMissing(let summary):
            return "引擎件不完整：\(summary)"
        case .engineExit(let code):
            return "引擎启动进程退出，代码 \(code)。请查看 fork 引擎日志。"
        }
    }
}

/// 工厂：fork 环境（dlsym 命中）用真引擎桥，纯外壳构建维持 M2 接缝实现。
enum LauncherEngineFactory {
    static func make() -> LauncherEngine {
        let host = YZLEngineHost()
        return host.isRuntimeLinked ? host : AmethystEngine()
    }
}
