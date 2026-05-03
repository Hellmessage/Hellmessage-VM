// hvm-cli/Support/EngineArgument.swift
// 给 HVMBundle.Engine 加 ArgumentParser conformance, 让 `--engine vz|qemu` 拼写错时
// ArgumentParser 自动报"invalid value 'foo' for '--engine'", 不再走 hvm-cli 内手动
// `Engine(rawValue:)` + throw HVMError.config(.invalidEnum). 这样 --help 也能自动列
// 出可选值.
//
// HVMBundle 不依赖 ArgumentParser (CLI 层依赖), 在 hvm-cli 一侧给 Engine 加 conformance.
// 同 SwiftPM package 内不需要 @retroactive (该属性仅给跨外部模块的 retroactive conformance).

import ArgumentParser
import HVMBundle

extension Engine: ExpressibleByArgument {
    // RawRepresentable<String> + CaseIterable, ArgumentParser 自动合成
    // init?(argument:) 与 allValueStrings, 不需手写.
}
