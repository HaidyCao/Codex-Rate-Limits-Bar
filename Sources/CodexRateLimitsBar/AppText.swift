import Foundation

enum AppText {
    private enum Language {
        case simplifiedChinese
        case traditionalChinese
        case japanese
        case korean
        case english
    }

    static var usageTitle: String {
        switch language {
        case .simplifiedChinese, .traditionalChinese: return "用量"
        case .japanese: return "使用状況"
        case .korean: return "사용량"
        case .english: return "Usage"
        }
    }

    static var fiveHourLimit: String {
        switch language {
        case .simplifiedChinese: return "5 小时"
        case .traditionalChinese: return "5 小時"
        case .japanese: return "5時間"
        case .korean: return "5시간"
        case .english: return "5 hours"
        }
    }

    static var weeklyLimit: String {
        switch language {
        case .simplifiedChinese: return "1 周"
        case .traditionalChinese: return "1 週"
        case .japanese: return "1週間"
        case .korean: return "1주"
        case .english: return "1 week"
        }
    }

    static var resetCreditsTitle: String {
        switch language {
        case .simplifiedChinese: return "重置券"
        case .traditionalChinese: return "重置券"
        case .japanese: return "リセット券"
        case .korean: return "초기화권"
        case .english: return "Reset credits"
        }
    }

    static var localUsageTitle: String {
        switch language {
        case .simplifiedChinese: return "Codex · 真实消耗 Tokens"
        case .traditionalChinese: return "Codex · 真實消耗 Tokens"
        case .japanese: return "Codex · 実消費 Tokens"
        case .korean: return "Codex · 실제 사용 Tokens"
        case .english: return "Codex · Actual Tokens"
        }
    }

    static var totalRequests: String {
        switch language {
        case .simplifiedChinese: return "总请求数"
        case .traditionalChinese: return "總請求數"
        case .japanese: return "リクエスト数"
        case .korean: return "총 요청 수"
        case .english: return "Requests"
        }
    }

    static var newInput: String {
        switch language {
        case .simplifiedChinese: return "新增输入"
        case .traditionalChinese: return "新增輸入"
        case .japanese: return "新規入力"
        case .korean: return "신규 입력"
        case .english: return "New input"
        }
    }

    static var output: String {
        switch language {
        case .simplifiedChinese: return "输出"
        case .traditionalChinese: return "輸出"
        case .japanese: return "出力"
        case .korean: return "출력"
        case .english: return "Output"
        }
    }

    static var hit: String {
        switch language {
        case .simplifiedChinese: return "命中"
        case .traditionalChinese: return "命中"
        case .japanese: return "ヒット"
        case .korean: return "히트"
        case .english: return "Hit"
        }
    }

    static var cacheHitRate: String {
        switch language {
        case .simplifiedChinese: return "缓存命中率"
        case .traditionalChinese: return "快取命中率"
        case .japanese: return "キャッシュヒット率"
        case .korean: return "캐시 적중률"
        case .english: return "Cache hit rate"
        }
    }

    static var launchTitle: String {
        switch language {
        case .simplifiedChinese: return "启动"
        case .traditionalChinese: return "啟動"
        case .japanese: return "起動"
        case .korean: return "시작"
        case .english: return "Launch"
        }
    }

    static var launchAtLogin: String {
        switch language {
        case .simplifiedChinese: return "在开机时启动"
        case .traditionalChinese: return "登入時啟動"
        case .japanese: return "ログイン時に起動"
        case .korean: return "로그인 시 시작"
        case .english: return "Launch at login"
        }
    }

    static var refreshNow: String {
        switch language {
        case .simplifiedChinese: return "立即刷新"
        case .traditionalChinese: return "立即重新整理"
        case .japanese: return "今すぐ更新"
        case .korean: return "지금 새로고침"
        case .english: return "Refresh Now"
        }
    }

    static var quit: String {
        switch language {
        case .simplifiedChinese: return "退出"
        case .traditionalChinese: return "結束"
        case .japanese: return "終了"
        case .korean: return "종료"
        case .english: return "Quit"
        }
    }

    static var autoLaunchFailure: String {
        switch language {
        case .simplifiedChinese: return "开机自启失败：请查看提示"
        case .traditionalChinese: return "登入啟動失敗：請查看提示"
        case .japanese: return "ログイン時起動に失敗：詳細を確認してください"
        case .korean: return "로그인 시 시작 실패: 도움말을 확인하세요"
        case .english: return "Launch at login failed: see tooltip"
        }
    }

    static var partialRefreshFailure: String {
        switch language {
        case .simplifiedChinese: return "部分刷新失败：请查看提示"
        case .traditionalChinese: return "部分重新整理失敗：請查看提示"
        case .japanese: return "一部の更新に失敗：詳細を確認してください"
        case .korean: return "일부 새로고침 실패: 도움말을 확인하세요"
        case .english: return "Partial refresh failed: see tooltip"
        }
    }

    static var rateLimitErrorLabel: String {
        switch language {
        case .simplifiedChinese: return "限额"
        case .traditionalChinese: return "限額"
        case .japanese: return "制限"
        case .korean: return "한도"
        case .english: return "Limit"
        }
    }

    static var localUsageErrorLabel: String {
        switch language {
        case .simplifiedChinese: return "本机用量"
        case .traditionalChinese: return "本機用量"
        case .japanese: return "ローカル使用量"
        case .korean: return "로컬 사용량"
        case .english: return "Local usage"
        }
    }

    static var refreshRateLimitUnavailable: String {
        switch language {
        case .simplifiedChinese: return "刷新失败：Codex 限额接口暂不可用"
        case .traditionalChinese: return "重新整理失敗：Codex 限額介面暫不可用"
        case .japanese: return "更新失敗：Codex 制限 API は一時的に利用できません"
        case .korean: return "새로고침 실패: Codex 한도 API를 사용할 수 없습니다"
        case .english: return "Refresh failed: Codex limit API unavailable"
        }
    }

    static var refreshUsageUnavailable: String {
        switch language {
        case .simplifiedChinese: return "刷新失败：Codex 用量接口暂不可用"
        case .traditionalChinese: return "重新整理失敗：Codex 用量介面暫不可用"
        case .japanese: return "更新失敗：Codex 使用量 API は一時的に利用できません"
        case .korean: return "새로고침 실패: Codex 사용량 API를 사용할 수 없습니다"
        case .english: return "Refresh failed: Codex usage API unavailable"
        }
    }

    static var refreshTimeout: String {
        switch language {
        case .simplifiedChinese: return "刷新失败：Codex 接口超时"
        case .traditionalChinese: return "重新整理失敗：Codex 介面逾時"
        case .japanese: return "更新失敗：Codex API がタイムアウトしました"
        case .korean: return "새로고침 실패: Codex API 시간 초과"
        case .english: return "Refresh failed: Codex API timed out"
        }
    }

    static var refreshStatusUnavailable: String {
        switch language {
        case .simplifiedChinese: return "刷新失败：Codex 状态暂不可用"
        case .traditionalChinese: return "重新整理失敗：Codex 狀態暫不可用"
        case .japanese: return "更新失敗：Codex 状態は一時的に利用できません"
        case .korean: return "새로고침 실패: Codex 상태를 사용할 수 없습니다"
        case .english: return "Refresh failed: Codex status unavailable"
        }
    }

    static var resetCreditsCategory: String {
        switch language {
        case .simplifiedChinese: return "Codex 速率限制重置"
        case .traditionalChinese: return "Codex 速率限制重置"
        case .japanese: return "Codex レート制限リセット"
        case .korean: return "Codex 속도 제한 초기화"
        case .english: return "Codex rate-limit resets"
        }
    }

    static var noResetCredits: String {
        switch language {
        case .simplifiedChinese: return "暂无可显示的重置券"
        case .traditionalChinese: return "暫無可顯示的重置券"
        case .japanese: return "表示できるリセット券はありません"
        case .korean: return "표시할 초기화권이 없습니다"
        case .english: return "No reset credits to show"
        }
    }

    static var resetCreditsUnavailable: String {
        switch language {
        case .simplifiedChinese: return "暂时无法读取重置券"
        case .traditionalChinese: return "暫時無法讀取重置券"
        case .japanese: return "リセット券を読み込めません"
        case .korean: return "초기화권을 읽을 수 없습니다"
        case .english: return "Reset credits unavailable"
        }
    }

    static var rateLimitStatusTooltip: String {
        switch language {
        case .simplifiedChinese: return "Codex 限额"
        case .traditionalChinese: return "Codex 限額"
        case .japanese: return "Codex 制限"
        case .korean: return "Codex 한도"
        case .english: return "Codex rate limits"
        }
    }

    static var localUsageStatusTooltip: String {
        switch language {
        case .simplifiedChinese: return "Codex 本机 token 用量"
        case .traditionalChinese: return "Codex 本機 token 用量"
        case .japanese: return "Codex ローカル token 使用量"
        case .korean: return "Codex 로컬 token 사용량"
        case .english: return "Codex local token usage"
        }
    }

    static var rateLimitRefreshFailedTooltip: String {
        switch language {
        case .simplifiedChinese: return "Codex 限额刷新失败；显示上次结果"
        case .traditionalChinese: return "Codex 限額重新整理失敗；顯示上次結果"
        case .japanese: return "Codex 制限の更新に失敗しました。前回の結果を表示しています"
        case .korean: return "Codex 한도 새로고침 실패; 마지막 결과 표시 중"
        case .english: return "Codex rate limit refresh failed; showing last value"
        }
    }

    static var localUsageRefreshFailedTooltip: String {
        switch language {
        case .simplifiedChinese: return "Codex 本机用量刷新失败；显示上次结果"
        case .traditionalChinese: return "Codex 本機用量重新整理失敗；顯示上次結果"
        case .japanese: return "Codex ローカル使用量の更新に失敗しました。前回の結果を表示しています"
        case .korean: return "Codex 로컬 사용량 새로고침 실패; 마지막 결과 표시 중"
        case .english: return "Codex local usage refresh failed; showing last value"
        }
    }

    static var unknownCategory: String {
        switch language {
        case .simplifiedChinese: return "未知分类"
        case .traditionalChinese: return "未知分類"
        case .japanese: return "不明なカテゴリ"
        case .korean: return "알 수 없는 분류"
        case .english: return "Unknown category"
        }
    }

    static var unknown: String {
        switch language {
        case .simplifiedChinese, .traditionalChinese: return "未知"
        case .japanese: return "不明"
        case .korean: return "알 수 없음"
        case .english: return "Unknown"
        }
    }

    static var notSet: String {
        switch language {
        case .simplifiedChinese: return "未设置"
        case .traditionalChinese: return "未設定"
        case .japanese: return "未設定"
        case .korean: return "설정 안 됨"
        case .english: return "Not set"
        }
    }

    static func availableCount(_ count: Int?) -> String {
        let value = count.map(String.init) ?? "--"
        switch language {
        case .simplifiedChinese: return "可用次数：\(value)"
        case .traditionalChinese: return "可用次數：\(value)"
        case .japanese: return "利用可能：\(value)"
        case .korean: return "사용 가능: \(value)"
        case .english: return "Available: \(value)"
        }
    }

    static func consumption(_ value: String?) -> String {
        let value = value ?? "--"
        switch language {
        case .simplifiedChinese: return "消耗 \(value)"
        case .traditionalChinese: return "消耗 \(value)"
        case .japanese: return "消費 \(value)"
        case .korean: return "사용 \(value)"
        case .english: return "Used \(value)"
        }
    }

    static func cacheHit(_ value: String?) -> String {
        let value = value ?? "--"
        switch language {
        case .simplifiedChinese: return "命中 \(value)"
        case .traditionalChinese: return "命中 \(value)"
        case .japanese: return "ヒット \(value)"
        case .korean: return "적중 \(value)"
        case .english: return "Hit \(value)"
        }
    }

    static func localUsageTooltip(tokens: String, cacheHit: String) -> String {
        switch language {
        case .simplifiedChinese: return "Codex 本机今日 \(tokens)，缓存命中 \(cacheHit)"
        case .traditionalChinese: return "Codex 本機今日 \(tokens)，快取命中 \(cacheHit)"
        case .japanese: return "Codex 今日のローカル使用量 \(tokens)、キャッシュヒット \(cacheHit)"
        case .korean: return "Codex 오늘 로컬 사용량 \(tokens), 캐시 적중 \(cacheHit)"
        case .english: return "Codex local today \(tokens), cache hit \(cacheHit)"
        }
    }

    static func rateLimitTooltip(primary: String, secondary: String, resetCount: Int?) -> String {
        switch language {
        case .simplifiedChinese:
            let suffix = resetCount.map { "，重置券 \($0)" } ?? ""
            return "Codex 5 小时 \(primary)，1 周 \(secondary)\(suffix)"
        case .traditionalChinese:
            let suffix = resetCount.map { "，重置券 \($0)" } ?? ""
            return "Codex 5 小時 \(primary)，1 週 \(secondary)\(suffix)"
        case .japanese:
            let suffix = resetCount.map { "、リセット券 \($0)" } ?? ""
            return "Codex 5時間 \(primary)、1週間 \(secondary)\(suffix)"
        case .korean:
            let suffix = resetCount.map { ", 초기화권 \($0)" } ?? ""
            return "Codex 5시간 \(primary), 1주 \(secondary)\(suffix)"
        case .english:
            let suffix = resetCount.map { ", resets \($0)" } ?? ""
            return "Codex 5h \(primary), week \(secondary)\(suffix)"
        }
    }

    static func localUsageDetail(events: Int, filesWithEvents: Int, filesScanned: Int) -> String {
        switch language {
        case .simplifiedChinese: return "事件 \(events) · 文件 \(filesWithEvents)/\(filesScanned)"
        case .traditionalChinese: return "事件 \(events) · 檔案 \(filesWithEvents)/\(filesScanned)"
        case .japanese: return "イベント \(events) · ファイル \(filesWithEvents)/\(filesScanned)"
        case .korean: return "이벤트 \(events) · 파일 \(filesWithEvents)/\(filesScanned)"
        case .english: return "Events \(events) · Files \(filesWithEvents)/\(filesScanned)"
        }
    }

    static func resetCreditDetail(index: Int, status: String?, expiresAt: String?) -> String {
        let expiration = expiresAt ?? notSet
        switch language {
        case .simplifiedChinese:
            return "\(index). \(status ?? unknown) · 到期 \(expiration)"
        case .traditionalChinese:
            return "\(index). \(status ?? unknown) · 到期 \(expiration)"
        case .japanese:
            return "\(index). \(status ?? unknown) · 期限 \(expiration)"
        case .korean:
            return "\(index). \(status ?? unknown) · 만료 \(expiration)"
        case .english:
            return "\(index). \(status ?? unknown) · Expires \(expiration)"
        }
    }

    static func resetCreditTypeLabel(_ value: String?) -> String {
        switch value {
        case "codex_rate_limits":
            return resetCreditsCategory
        case let value? where !value.isEmpty:
            return value
        default:
            return unknownCategory
        }
    }

    static func resetCreditStatusLabel(_ value: String?) -> String {
        switch value {
        case "available":
            switch language {
            case .simplifiedChinese, .traditionalChinese: return "可用"
            case .japanese: return "利用可能"
            case .korean: return "사용 가능"
            case .english: return "Available"
            }
        case "redeemed":
            switch language {
            case .simplifiedChinese: return "已兑换"
            case .traditionalChinese: return "已兌換"
            case .japanese: return "交換済み"
            case .korean: return "교환됨"
            case .english: return "Redeemed"
            }
        case "expired":
            switch language {
            case .simplifiedChinese: return "已过期"
            case .traditionalChinese: return "已過期"
            case .japanese: return "期限切れ"
            case .korean: return "만료됨"
            case .english: return "Expired"
            }
        case "used":
            switch language {
            case .simplifiedChinese: return "已使用"
            case .traditionalChinese: return "已使用"
            case .japanese: return "使用済み"
            case .korean: return "사용됨"
            case .english: return "Used"
            }
        case let value? where !value.isEmpty:
            return value
        default:
            return unknown
        }
    }

    static func resetDateTime(_ iso: String?, short: Bool) -> String {
        guard let date = parseIsoDate(iso) else { return notSet }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone.current
        formatter.setLocalizedDateFormatFromTemplate(short ? "MMMdHHmm" : "yyyyMMMdHHmmss")
        return formatter.string(from: date)
    }

    static func resetDisplay(_ date: Date, includeDate: Bool) -> String {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let display = DateFormatter()
        display.locale = locale
        display.timeZone = TimeZone.current
        if includeDate || !calendar.isDateInToday(date) {
            display.setLocalizedDateFormatFromTemplate(
                calendar.component(.year, from: date) == calendar.component(.year, from: Date()) ? "MMMdHHmm" : "yyyyMMMdHHmm"
            )
        } else {
            display.setLocalizedDateFormatFromTemplate("HHmm")
        }
        return display.string(from: date)
    }

    private static var language: Language {
        let preferred = Locale.preferredLanguages.first ?? Locale.autoupdatingCurrent.identifier
        return language(for: preferred)
    }

    private static var locale: Locale {
        Locale(identifier: Locale.preferredLanguages.first ?? Locale.autoupdatingCurrent.identifier)
    }

    private static func language(for identifier: String) -> Language {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        let parts = normalized.split(separator: "-").map(String.init)
        guard let language = parts.first else { return .english }
        switch language {
        case "ja":
            return .japanese
        case "ko":
            return .korean
        case "zh", "yue":
            if normalized.contains("-hant")
                || normalized.contains("-hk")
                || normalized.contains("-tw")
                || normalized.contains("-mo")
            {
                return .traditionalChinese
            }
            return .simplifiedChinese
        default:
            return .english
        }
    }

    private static func parseIsoDate(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: iso) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }
}
