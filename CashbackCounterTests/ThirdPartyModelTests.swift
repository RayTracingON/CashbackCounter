import XCTest
import FoundationModels
@testable import CashbackCounter

/// 第三方模型通道里两块纯逻辑的回归测试：
/// schema 方言转换（字段顺序！）和模型输出清洗。
/// 这两块是最容易悄悄坏掉的地方——坏了不会崩，只会让解析结果全 nil。
final class ThirdPartyModelTests: XCTestCase {

    // MARK: - 字段顺序

    /// 项目里最要命的隐形约束：ReceiptMetadata / CloudReceiptMetadata 的字段顺序
    /// 是真机验证过的配方，顺序一乱模型就开始连环输出 nil。
    /// JSON 对象本身无序，全靠 GenerationSchema 编码里的 x-order 还原。
    func testSchemaPreservesDeclaredPropertyOrder_Local() throws {
        let json = try SchemaJSON.from(ReceiptMetadata.generationSchema)
        XCTAssertEqual(
            propertyNames(of: json),
            ["category", "cardLast4", "dateString", "currency", "totalAmount", "merchant"]
        )
    }

    func testSchemaPreservesDeclaredPropertyOrder_Cloud() throws {
        let json = try SchemaJSON.from(CloudReceiptMetadata.generationSchema)
        XCTAssertEqual(
            propertyNames(of: json),
            ["merchant", "totalAmount", "currency", "dateString", "cardLast4", "category"]
        )
    }

    /// 序列化后的字节序也必须保住顺序——真正发给模型的是这串文本
    func testSerializedSchemaKeepsPropertyOrder() throws {
        let text = try SchemaJSON.from(CloudReceiptMetadata.generationSchema)
            .standardJSONSchema()
            .serialized()
        let positions = ["merchant", "totalAmount", "currency", "dateString", "cardLast4", "category"]
            .map { text.range(of: "\"\($0)\"")?.lowerBound }
        XCTAssertFalse(positions.contains(where: { $0 == nil }), "所有字段都应出现在序列化结果里")
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted())
    }

    // MARK: - 通用方言

    func testStandardSchemaStripsInternalKeys() throws {
        let text = try SchemaJSON.from(ReceiptMetadata.generationSchema)
            .standardJSONSchema()
            .serialized()
        XCTAssertFalse(text.contains("x-order"), "x-order 是内部键，不能发给任何 API")
    }

    // MARK: - OpenAI strict

    /// strict:true 要求所有属性都进 required，可选字段改用可空类型表达
    func testOpenAIStrictMakesEveryPropertyRequired() throws {
        let strict = try SchemaJSON.from(ReceiptMetadata.generationSchema).openAIStrictSchema()

        let required = strict["required"]?.arrayValue?.compactMap { $0.stringValue }
        XCTAssertEqual(required, propertyNames(of: strict))
        XCTAssertEqual(strict["additionalProperties"].flatMap(boolValue), false)
        XCTAssertFalse(strict.serialized().contains("x-order"))
    }

    func testOpenAIStrictMarksOptionalScalarsNullable() throws {
        let strict = try SchemaJSON.from(ReceiptMetadata.generationSchema).openAIStrictSchema()
        let merchant = strict["properties"]?["merchant"]

        // 全可选的标量 → type: ["string", "null"]
        let types = merchant?["type"]?.arrayValue?.compactMap { $0.stringValue }
        XCTAssertEqual(types, ["string", "null"])
    }

    /// enum 节点不能靠 type 数组表达可空（会和取值集合打架），必须包 anyOf
    func testOpenAIStrictWrapsOptionalEnumInAnyOf() throws {
        let strict = try SchemaJSON.from(ReceiptMetadata.generationSchema).openAIStrictSchema()
        let category = strict["properties"]?["category"]

        XCTAssertNotNil(category?["anyOf"], "可选枚举应被包进 anyOf")
        let branches = category?["anyOf"]?.arrayValue ?? []
        XCTAssertEqual(branches.count, 2)
        XCTAssertNotNil(branches.first?["enum"] ?? branches.first?["$ref"])
        XCTAssertEqual(branches.last?["type"]?.stringValue, "null")
    }

    // MARK: - Gemini 方言

    func testGeminiSchemaInlinesRefsAndDropsDefs() throws {
        let gemini = try SchemaJSON.from(StatementRowTransactionList.generationSchema).geminiSchema()
        let text = gemini.serialized()

        XCTAssertFalse(text.contains("$defs"), "Gemini 不认 $defs")
        XCTAssertFalse(text.contains("$ref"), "Gemini 不认 $ref，必须内联展开")
        XCTAssertFalse(text.contains("additionalProperties"), "Gemini 不认 additionalProperties")

        // 数组元素应该被展开成完整的对象 schema
        let items = gemini["properties"]?["transactions"]?["items"]
        XCTAssertNotNil(items?["properties"], "数组元素应内联成完整对象 schema")
    }

    func testGeminiSchemaUsesPropertyOrderingAndUppercaseTypes() throws {
        let gemini = try SchemaJSON.from(CloudReceiptMetadata.generationSchema).geminiSchema()

        XCTAssertEqual(gemini["type"]?.stringValue, "OBJECT")
        XCTAssertEqual(
            gemini["propertyOrdering"]?.arrayValue?.compactMap { $0.stringValue },
            ["merchant", "totalAmount", "currency", "dateString", "cardLast4", "category"]
        )
        XCTAssertEqual(gemini["properties"]?["merchant"]?["type"]?.stringValue, "STRING")
        XCTAssertEqual(gemini["properties"]?["totalAmount"]?["type"]?.stringValue, "NUMBER")
        XCTAssertEqual(gemini["properties"]?["merchant"]?["nullable"].flatMap(boolValue), true)
        XCTAssertFalse(gemini.serialized().contains("x-order"))
    }

    // MARK: - 输出清洗

    func testExtractorUnwrapsMarkdownFence() {
        let raw = "```json\n{\"merchant\":\"7-Eleven\"}\n```"
        XCTAssertEqual(JSONResponseExtractor.extract(from: raw), "{\"merchant\":\"7-Eleven\"}")
    }

    func testExtractorDropsSurroundingProse() {
        let raw = "Sure! Here is the result:\n{\"merchant\":\"Lawson\"}\nLet me know if you need more."
        XCTAssertEqual(JSONResponseExtractor.extract(from: raw), "{\"merchant\":\"Lawson\"}")
    }

    func testExtractorDropsReasoningBlock() {
        let raw = "<think>The receipt says Lawson, total 500 yen.</think>\n{\"totalAmount\":500}"
        XCTAssertEqual(JSONResponseExtractor.extract(from: raw), "{\"totalAmount\":500}")
    }

    /// 商户名里带大括号或引号时不能把 JSON 截断在半路
    func testExtractorHandlesBracesInsideStrings() {
        let raw = "{\"merchant\":\"Cafe {Bloom}\",\"note\":\"a \\\"quoted\\\" name\"}"
        XCTAssertEqual(JSONResponseExtractor.extract(from: raw), raw)
    }

    func testExtractorHandlesNestedObjects() {
        let raw = "prefix {\"a\":{\"b\":[1,2,{\"c\":3}]}} suffix"
        XCTAssertEqual(JSONResponseExtractor.extract(from: raw), "{\"a\":{\"b\":[1,2,{\"c\":3}]}}")
    }

    func testExtractorPassesThroughPlainJSON() {
        let raw = "{\"merchant\":\"FamilyMart\"}"
        XCTAssertEqual(JSONResponseExtractor.extract(from: raw), raw)
    }

    // MARK: - 配置校验

    func testConfigRejectsIncompleteInput() {
        var config = ThirdPartyModelConfig()
        config.modelName = ""
        XCTAssertFalse(config.isComplete, "缺模型名不算配置完整")

        config.modelName = "gpt-4.1-mini"
        config.baseURL = "not a url"
        XCTAssertNil(config.normalizedBaseURL)
        XCTAssertFalse(config.isComplete)

        config.baseURL = "https://api.deepseek.com/v1/"
        XCTAssertEqual(config.normalizedBaseURL?.absoluteString, "https://api.deepseek.com/v1")
        XCTAssertTrue(config.isComplete)
    }

    /// 换服务商或换模型后，之前探明的结构化输出档位必须失效
    func testProbeCacheKeyChangesWithEndpointAndModel() {
        var a = ThirdPartyModelConfig()
        a.baseURL = "https://api.openai.com/v1"
        a.modelName = "gpt-4.1-mini"

        var b = a
        b.modelName = "gpt-4.1"
        XCTAssertNotEqual(a.probeCacheKey, b.probeCacheKey)

        var c = a
        c.provider = .anthropic
        XCTAssertNotEqual(a.probeCacheKey, c.probeCacheKey)
    }

    // MARK: - Helpers

    private func propertyNames(of schema: SchemaJSON) -> [String] {
        schema["properties"]?.objectPairs?.map(\.key) ?? []
    }

    private func boolValue(_ json: SchemaJSON) -> Bool? {
        if case .bool(let value) = json { return value }
        return nil
    }
}
