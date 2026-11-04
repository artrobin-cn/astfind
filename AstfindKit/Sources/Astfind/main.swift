// Astfind App 入口：oil-find 面板 + Astfind 多来源扩展（统一搜索本机/外置/NAS）。
// 公开构建永远不含闭源 Pro（ADL-118）。
import AstfindPanel
import AstfindKit

Application.run(appExtension: AstfindAppExtension())
