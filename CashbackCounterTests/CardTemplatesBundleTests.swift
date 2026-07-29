import XCTest
@testable import CashbackCounter

/// 内置 CardTemplates.json 必须始终可解码。
///
/// 存在的理由是一次真实事故：这个文件里有一处 `"foreignCurrencyRate" : ,`
/// （冒号后面没有值），整个文件因此不是合法 JSON。
///
/// 后果被放大了两次：
///   1. 同一份文件既是**远端配置**又是**内置兜底**，所以两条路径同时失败 ——
///      名义上的 fallback 根本没有起到 fallback 的作用
///   2. `CardTemplateManager.syncTemplates` 捕获异常后只 print 一行，
///      `templates` 静默保持为空
///
/// 用户看到的就是"卡片模版全没了"，没有任何错误提示，也没有任何线索指向 JSON。
/// 这种错误必须在合并前被挡住。
final class CardTemplatesBundleTests: XCTestCase {

    func testBundledTemplatesDecode() throws {
        guard let url = Bundle.main.url(forResource: "CardTemplates", withExtension: "json") else {
            XCTFail("App bundle 里找不到 CardTemplates.json —— 它是远端拉取失败时的唯一兜底")
            return
        }

        let data = try Data(contentsOf: url)

        let templates: [CardTemplate]
        do {
            templates = try JSONDecoder().decode([CardTemplate].self, from: data)
        } catch {
            // 把 Decoding 错误原样带出来：它会指出是哪个字段、第几条出的问题，
            // 比"解析失败"有用得多
            XCTFail("CardTemplates.json 无法解码，模版库会整个变空。原因: \(error)")
            return
        }

        XCTAssertFalse(templates.isEmpty, "模版列表为空，等同于功能不可用")

        // 每条至少要有银行名和卡种，否则在选择列表里是一行空白
        for template in templates {
            XCTAssertFalse(template.bankName.trimmingCharacters(in: .whitespaces).isEmpty,
                           "存在没有银行名的模版")
            XCTAssertFalse(template.type.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(template.bankName) 有一条模版没有卡种名")
        }
    }
}
