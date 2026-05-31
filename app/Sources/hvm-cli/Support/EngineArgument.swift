// hvm-cli/Support/EngineArgument.swift
// 给 HVMBundle.Engine 加 ArgumentParser conformance, 让 `--engine` 拼写错时自动报 invalid value
// + --help 自动列可选值. 同 package 内不需要 @retroactive.

import ArgumentParser
import HVMBundle

extension Engine: ExpressibleByArgument {
    // RawRepresentable<String> + CaseIterable, ArgumentParser 自动合成
    // init?(argument:) 与 allValueStrings, 不需手写.
}
