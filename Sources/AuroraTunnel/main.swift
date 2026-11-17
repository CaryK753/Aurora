//  main.swift
//  AuroraTunnel — 系统扩展入口
//
//  开发者 ID 直装不能用 .appex。系统扩展自己有 main，交给 NetworkExtension 之后停在 run loop 上。

import NetworkExtension

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
