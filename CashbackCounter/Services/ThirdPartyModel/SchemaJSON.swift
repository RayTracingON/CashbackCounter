//
//  SchemaJSON.swift
//  CashbackCounter
//
//  GenerationSchema → 各家 API 的 JSON Schema 方言。
//
//  为什么要自己写一个有序 JSON 类型而不是直接用 [String: Any]：
//  Foundation 的字典无序，而 **字段顺序在这个项目里是有语义的**
//  —— ReceiptMetadata / CloudReceiptMetadata 的字段声明顺序经过真机验证，
//  顺序一变模型就开始连环输出 nil（见 ReceiptModels.swift 顶部注释）。
//  好在 GenerationSchema 编码出来自带 "x-order" 数组记录了声明顺序，
//  这里用它把 properties 重新排好，再原样序列化出去。
//

import Foundation
import FoundationModels

// MARK: - 有序 JSON

/// 保序的 JSON 值。只覆盖 JSON Schema 用得到的形态。
indirect enum SchemaJSON: Sendable {
    case object([(key: String, value: SchemaJSON)])
    case array([SchemaJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    // MARK: 访问器

    var objectPairs: [(key: String, value: SchemaJSON)]? {
        if case .object(let pairs) = self { return pairs }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var arrayValue: [SchemaJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    subscript(key: String) -> SchemaJSON? {
        objectPairs?.first { $0.key == key }?.value
    }

    /// 就地设置/新增一个键，保持既有顺序；新键追加在末尾
    func setting(_ key: String, _ value: SchemaJSON?) -> SchemaJSON {
        guard var pairs = objectPairs else { return self }
        if let index = pairs.firstIndex(where: { $0.key == key }) {
            if let value { pairs[index].value = value } else { pairs.remove(at: index) }
        } else if let value {
            pairs.append((key, value))
        }
        return .object(pairs)
    }

    func removing(_ keys: Set<String>) -> SchemaJSON {
        guard let pairs = objectPairs else { return self }
        return .object(pairs.filter { !keys.contains($0.key) })
    }
}

// MARK: - 构造

extension SchemaJSON {

    /// 从 GenerationSchema 生成。GenerationSchema: Codable，编码结果就是标准 JSON Schema
    /// （additionalProperties/required/$defs/$ref 齐全），额外带一个 "x-order" 声明顺序数组。
    static func from(_ schema: GenerationSchema) throws -> SchemaJSON {
        let data = try JSONEncoder().encode(schema)
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        return SchemaJSON(raw)
    }

    init(_ raw: Any) {
        switch raw {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // NSNumber 会把 true/false 也装进来，得先按 CFBoolean 认一遍
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { SchemaJSON($0) })
        case let dict as [String: Any]:
            self = .object(SchemaJSON.orderedPairs(from: dict))
        default:
            self = .null
        }
    }

    /// JSON Schema 关键字的书写顺序。纯粹为了可读性（调试输出、写进 prompt 时给人/模型看），
    /// 唯一有语义的是 properties 内部的顺序，那个由 x-order 决定。
    private static let keywordOrder: [String] = [
        "$schema", "$ref", "title", "type", "format", "description", "nullable",
        "enum", "const", "properties", "propertyOrdering", "required",
        "items", "minItems", "maxItems", "anyOf", "oneOf", "allOf",
        "pattern", "additionalProperties", "$defs", "x-order"
    ]

    private static func orderedPairs(from dict: [String: Any]) -> [(key: String, value: SchemaJSON)] {
        // properties 的顺序按同级 x-order 还原；x-order 里没提到的（理论上不该有）排在后面
        let declaredOrder = (dict["x-order"] as? [String]) ?? []

        let sortedKeys = dict.keys.sorted { lhs, rhs in
            let l = keywordOrder.firstIndex(of: lhs) ?? Int.max
            let r = keywordOrder.firstIndex(of: rhs) ?? Int.max
            return l == r ? lhs < rhs : l < r
        }

        return sortedKeys.map { key in
            let value = dict[key]!
            if key == "properties", let props = value as? [String: Any], !declaredOrder.isEmpty {
                return (key, .object(orderedProperties(props, following: declaredOrder)))
            }
            return (key, SchemaJSON(value))
        }
    }

    private static func orderedProperties(
        _ props: [String: Any],
        following order: [String]
    ) -> [(key: String, value: SchemaJSON)] {
        var pairs: [(key: String, value: SchemaJSON)] = []
        var remaining = Set(props.keys)
        for name in order where props[name] != nil {
            pairs.append((name, SchemaJSON(props[name]!)))
            remaining.remove(name)
        }
        for name in remaining.sorted() {
            pairs.append((name, SchemaJSON(props[name]!)))
        }
        return pairs
    }
}

// MARK: - 序列化

extension SchemaJSON {

    /// 自己写序列化而不是走 JSONSerialization：后者接受的是无序字典，一过它顺序就没了。
    func serialized() -> String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            // schema 里的数值都是整数语义（minItems 等），能整就整，避免写出 "2.0"
            if value == value.rounded(), abs(value) < 1e15 {
                return String(Int64(value))
            }
            return String(value)
        case .string(let value):
            return Self.encodeString(value)
        case .array(let items):
            return "[" + items.map { $0.serialized() }.joined(separator: ",") + "]"
        case .object(let pairs):
            let body = pairs
                .map { Self.encodeString($0.key) + ":" + $0.value.serialized() }
                .joined(separator: ",")
            return "{" + body + "}"
        }
    }

    var jsonData: Data { Data(serialized().utf8) }

    private static func encodeString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - 方言转换

extension SchemaJSON {

    /// 内部用的元信息键，不能出现在发给任何一家 API 的 schema 里
    private static let internalKeys: Set<String> = ["x-order"]

    /// 通用 JSON Schema：只剥掉内部键。
    /// 用于 Anthropic 的 tool input_schema，以及 OpenAI 非 strict 模式。
    /// （properties 的顺序已经在构造时排好，序列化时原样保留。）
    func standardJSONSchema() -> SchemaJSON {
        transformObjects { node in node.removing(Self.internalKeys) }
    }

    /// OpenAI strict 模式方言。
    /// strict:true 要求：每个 object 的 properties **全部**列进 required、
    /// additionalProperties 必须为 false、且不认识的关键字会直接报错。
    /// 所以原本的可选字段要改写成「可为 null」再全部塞进 required。
    func openAIStrictSchema() -> SchemaJSON {
        transformObjects { node in
            var result = node.removing(Self.internalKeys.union(["title"]))
            guard node["type"]?.stringValue == "object",
                  let props = node["properties"]?.objectPairs else { return result }

            let required = Set(node["required"]?.arrayValue?.compactMap { $0.stringValue } ?? [])
            let rewritten = props.map { pair -> (key: String, value: SchemaJSON) in
                required.contains(pair.key) ? pair : (pair.key, pair.value.madeNullable())
            }

            result = result.setting("properties", .object(rewritten))
            result = result.setting("required", .array(props.map { .string($0.key) }))
            result = result.setting("additionalProperties", .bool(false))
            return result
        }
    }

    /// Gemini responseSchema 方言（OpenAPI 3.0 子集）：
    /// 不认 $defs/$ref/additionalProperties/title，字段顺序靠自己的 propertyOrdering，
    /// 可空性靠 nullable:true，type 用大写枚举名。
    func geminiSchema() -> SchemaJSON {
        let defs = self["$defs"]?.objectPairs ?? []
        let inlined = inliningRefs(defs: defs, depth: 0)
        return inlined.transformObjects { node in
            var result = node.removing(["$defs", "additionalProperties", "title", "x-order"])

            // x-order → propertyOrdering（Gemini 自己的字段顺序提示）
            if let order = node["x-order"]?.arrayValue, !order.isEmpty {
                result = result.setting("propertyOrdering", .array(order))
            }

            if node["type"]?.stringValue == "object", let props = node["properties"]?.objectPairs {
                let required = Set(node["required"]?.arrayValue?.compactMap { $0.stringValue } ?? [])
                let rewritten = props.map { pair -> (key: String, value: SchemaJSON) in
                    required.contains(pair.key)
                        ? pair
                        : (pair.key, pair.value.setting("nullable", .bool(true)))
                }
                result = result.setting("properties", .object(rewritten))
            }

            // protobuf JSON 的枚举名是大写的
            if let type = result["type"]?.stringValue {
                result = result.setting("type", .string(type.uppercased()))
            }
            return result
        }
    }

    // MARK: 转换基元

    /// JSON Schema 里「值是另一个 schema」的键
    private static let schemaValuedKeys: Set<String> = ["items", "additionalItems", "contains"]
    /// 值是「名字 → schema」映射的键
    private static let schemaMapKeys: Set<String> = ["properties", "$defs", "definitions", "patternProperties"]
    /// 值是 schema 数组的键
    private static let schemaListKeys: Set<String> = ["anyOf", "oneOf", "allOf", "prefixItems"]

    /// 自底向上遍历真正的 schema 节点。
    /// ⚠️ 不能无脑对每个 object 递归：properties / $defs 的**值本身**是
    /// 「名字 → schema」的映射容器，不是 schema。把它当 schema 处理的话，
    /// 一个名叫 title 或 x-order 的业务字段会被当成关键字直接删掉。
    private func transformObjects(_ transform: (SchemaJSON) -> SchemaJSON) -> SchemaJSON {
        guard let pairs = objectPairs else { return self }

        let mapped = pairs.map { pair -> (key: String, value: SchemaJSON) in
            if Self.schemaMapKeys.contains(pair.key), let inner = pair.value.objectPairs {
                return (pair.key, .object(inner.map {
                    (key: $0.key, value: $0.value.transformObjects(transform))
                }))
            }
            if Self.schemaValuedKeys.contains(pair.key) {
                return (pair.key, pair.value.transformObjects(transform))
            }
            if Self.schemaListKeys.contains(pair.key), let list = pair.value.arrayValue {
                return (pair.key, .array(list.map { $0.transformObjects(transform) }))
            }
            return pair
        }
        return transform(.object(mapped))
    }

    /// 把 $ref 就地展开成 $defs 里的定义。Gemini 不支持引用，只能全部内联。
    /// depth 上限防的是自引用类型（本项目没有，但别在这里死循环）。
    private func inliningRefs(defs: [(key: String, value: SchemaJSON)], depth: Int) -> SchemaJSON {
        guard depth < 8, let pairs = objectPairs else { return self }

        if let ref = self["$ref"]?.stringValue,
           let name = ref.split(separator: "/").last.map(String.init),
           let target = defs.first(where: { $0.key == name })?.value {
            return target.inliningRefs(defs: defs, depth: depth + 1)
        }

        return .object(pairs.map { pair -> (key: String, value: SchemaJSON) in
            if Self.schemaMapKeys.contains(pair.key), let inner = pair.value.objectPairs {
                return (pair.key, .object(inner.map {
                    (key: $0.key, value: $0.value.inliningRefs(defs: defs, depth: depth))
                }))
            }
            if Self.schemaValuedKeys.contains(pair.key) {
                return (pair.key, pair.value.inliningRefs(defs: defs, depth: depth))
            }
            if Self.schemaListKeys.contains(pair.key), let list = pair.value.arrayValue {
                return (pair.key, .array(list.map { $0.inliningRefs(defs: defs, depth: depth) }))
            }
            return pair
        })
    }

    /// 把一个属性节点改写成「可为 null」。
    /// enum / $ref / anyOf 这类节点没法在 type 上直接加 null（会和取值集合打架），
    /// 统一包一层 anyOf；普通标量才用 type 数组。
    private func madeNullable() -> SchemaJSON {
        if self["enum"] != nil || self["$ref"] != nil || self["anyOf"] != nil {
            return .object([("anyOf", .array([self, .object([("type", .string("null"))])]))])
        }
        if let type = self["type"]?.stringValue {
            return setting("type", .array([.string(type), .string("null")]))
        }
        return .object([("anyOf", .array([self, .object([("type", .string("null"))])]))])
    }
}
