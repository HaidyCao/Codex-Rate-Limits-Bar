import Foundation

public enum AppText {
    private enum Language {
        case simplifiedChinese
        case traditionalChinese
        case japanese
        case korean
        case english
    }

    public static var usageTitle: String {
        switch language {
        case .simplifiedChinese, .traditionalChinese: return "用量"
        case .japanese: return "使用状況"
        case .korean: return "사용량"
        case .english: return "Usage"
        }
    }

    public static var weeklyLimit: String {
        switch language {
        case .simplifiedChinese: return "1 周"
        case .traditionalChinese: return "1 週"
        case .japanese: return "1週間"
        case .korean: return "1주"
        case .english: return "1 week"
        }
    }

    public static var resetCreditsTitle: String {
        switch language {
        case .simplifiedChinese: return "重置券"
        case .traditionalChinese: return "重置券"
        case .japanese: return "リセット券"
        case .korean: return "초기화권"
        case .english: return "Reset credits"
        }
    }

    public static var localUsageTitle: String {
        switch language {
        case .simplifiedChinese: return "Codex · 真实消耗 Tokens"
        case .traditionalChinese: return "Codex · 真實消耗 Tokens"
        case .japanese: return "Codex · 実消費 Tokens"
        case .korean: return "Codex · 실제 사용 Tokens"
        case .english: return "Codex · Actual Tokens"
        }
    }

    public static var totalRequests: String {
        switch language {
        case .simplifiedChinese: return "总请求数"
        case .traditionalChinese: return "總請求數"
        case .japanese: return "リクエスト数"
        case .korean: return "총 요청 수"
        case .english: return "Requests"
        }
    }

    public static var newInput: String {
        switch language {
        case .simplifiedChinese: return "新增输入"
        case .traditionalChinese: return "新增輸入"
        case .japanese: return "新規入力"
        case .korean: return "신규 입력"
        case .english: return "New input"
        }
    }

    public static var output: String {
        switch language {
        case .simplifiedChinese: return "输出"
        case .traditionalChinese: return "輸出"
        case .japanese: return "出力"
        case .korean: return "출력"
        case .english: return "Output"
        }
    }

    public static var hit: String {
        switch language {
        case .simplifiedChinese: return "命中"
        case .traditionalChinese: return "命中"
        case .japanese: return "ヒット"
        case .korean: return "히트"
        case .english: return "Hit"
        }
    }

    public static var cacheHitRate: String {
        switch language {
        case .simplifiedChinese: return "缓存命中率"
        case .traditionalChinese: return "快取命中率"
        case .japanese: return "キャッシュヒット率"
        case .korean: return "캐시 적중률"
        case .english: return "Cache hit rate"
        }
    }

    public static var launchTitle: String {
        switch language {
        case .simplifiedChinese: return "启动"
        case .traditionalChinese: return "啟動"
        case .japanese: return "起動"
        case .korean: return "시작"
        case .english: return "Launch"
        }
    }

    public static var launchAtLogin: String {
        switch language {
        case .simplifiedChinese: return "在开机时启动"
        case .traditionalChinese: return "登入時啟動"
        case .japanese: return "ログイン時に起動"
        case .korean: return "로그인 시 시작"
        case .english: return "Launch at login"
        }
    }

    public static var showLocalUsageStatusItem: String {
        switch language {
        case .simplifiedChinese: return "显示消耗和命中状态栏"
        case .traditionalChinese: return "顯示消耗與命中狀態列"
        case .japanese: return "消費とヒット率をメニューバーに表示"
        case .korean: return "사용량과 적중률을 메뉴 막대에 표시"
        case .english: return "Show usage and cache hit in menu bar"
        }
    }

    public static var enableQuotaAlerts: String {
        switch language {
        case .simplifiedChinese: return "启用额度预警通知"
        case .traditionalChinese: return "啟用額度預警通知"
        case .japanese: return "上限アラート通知を有効にする"
        case .korean: return "한도 경고 알림 사용"
        case .english: return "Enable quota alert notifications"
        }
    }

    public static var refreshNow: String {
        switch language {
        case .simplifiedChinese: return "立即刷新"
        case .traditionalChinese: return "立即重新整理"
        case .japanese: return "今すぐ更新"
        case .korean: return "지금 새로고침"
        case .english: return "Refresh Now"
        }
    }

    public static var quit: String {
        switch language {
        case .simplifiedChinese: return "退出"
        case .traditionalChinese: return "結束"
        case .japanese: return "終了"
        case .korean: return "종료"
        case .english: return "Quit"
        }
    }

    public static var autoLaunchFailure: String {
        switch language {
        case .simplifiedChinese: return "开机自启失败：请查看提示"
        case .traditionalChinese: return "登入啟動失敗：請查看提示"
        case .japanese: return "ログイン時起動に失敗：詳細を確認してください"
        case .korean: return "로그인 시 시작 실패: 도움말을 확인하세요"
        case .english: return "Launch at login failed: see tooltip"
        }
    }

    public static var partialRefreshFailure: String {
        switch language {
        case .simplifiedChinese: return "部分刷新失败：请查看提示"
        case .traditionalChinese: return "部分重新整理失敗：請查看提示"
        case .japanese: return "一部の更新に失敗：詳細を確認してください"
        case .korean: return "일부 새로고침 실패: 도움말을 확인하세요"
        case .english: return "Partial refresh failed: see tooltip"
        }
    }

    public static var rateLimitErrorLabel: String {
        switch language {
        case .simplifiedChinese: return "限额"
        case .traditionalChinese: return "限額"
        case .japanese: return "制限"
        case .korean: return "한도"
        case .english: return "Limit"
        }
    }

    public static var localUsageErrorLabel: String {
        switch language {
        case .simplifiedChinese: return "本机用量"
        case .traditionalChinese: return "本機用量"
        case .japanese: return "ローカル使用量"
        case .korean: return "로컬 사용량"
        case .english: return "Local usage"
        }
    }

    public static var quotaAlertsErrorLabel: String {
        switch language {
        case .simplifiedChinese: return "额度预警"
        case .traditionalChinese: return "額度預警"
        case .japanese: return "上限アラート"
        case .korean: return "한도 경고"
        case .english: return "Quota alerts"
        }
    }

    public static var quotaForecastErrorLabel: String {
        switch language {
        case .simplifiedChinese: return "耗尽预测"
        case .traditionalChinese: return "用盡預測"
        case .japanese: return "上限到達予測"
        case .korean: return "소진 예측"
        case .english: return "Exhaustion forecast"
        }
    }

    public static var notificationPermissionDenied: String {
        switch language {
        case .simplifiedChinese: return "通知权限未开启，请在系统设置中允许通知"
        case .traditionalChinese: return "通知權限未開啟，請在系統設定中允許通知"
        case .japanese: return "通知が許可されていません。システム設定で通知を許可してください"
        case .korean: return "알림 권한이 꺼져 있습니다. 시스템 설정에서 알림을 허용하세요"
        case .english: return "Notifications are disabled; allow them in System Settings"
        }
    }

    public static var quotaForecastLabelPlaceholder: String {
        switch language {
        case .simplifiedChinese: return "正在等待额度数据"
        case .traditionalChinese: return "正在等待額度資料"
        case .japanese: return "上限データを待っています"
        case .korean: return "한도 데이터를 기다리는 중"
        case .english: return "Waiting for quota data"
        }
    }

    public static var refreshRateLimitUnavailable: String {
        switch language {
        case .simplifiedChinese: return "刷新失败：Codex 限额接口暂不可用"
        case .traditionalChinese: return "重新整理失敗：Codex 限額介面暫不可用"
        case .japanese: return "更新失敗：Codex 制限 API は一時的に利用できません"
        case .korean: return "새로고침 실패: Codex 한도 API를 사용할 수 없습니다"
        case .english: return "Refresh failed: Codex limit API unavailable"
        }
    }

    public static var refreshUsageUnavailable: String {
        switch language {
        case .simplifiedChinese: return "刷新失败：Codex 用量接口暂不可用"
        case .traditionalChinese: return "重新整理失敗：Codex 用量介面暫不可用"
        case .japanese: return "更新失敗：Codex 使用量 API は一時的に利用できません"
        case .korean: return "새로고침 실패: Codex 사용량 API를 사용할 수 없습니다"
        case .english: return "Refresh failed: Codex usage API unavailable"
        }
    }

    public static var refreshTimeout: String {
        switch language {
        case .simplifiedChinese: return "刷新失败：Codex 接口超时"
        case .traditionalChinese: return "重新整理失敗：Codex 介面逾時"
        case .japanese: return "更新失敗：Codex API がタイムアウトしました"
        case .korean: return "새로고침 실패: Codex API 시간 초과"
        case .english: return "Refresh failed: Codex API timed out"
        }
    }

    public static var refreshStatusUnavailable: String {
        switch language {
        case .simplifiedChinese: return "刷新失败：Codex 状态暂不可用"
        case .traditionalChinese: return "重新整理失敗：Codex 狀態暫不可用"
        case .japanese: return "更新失敗：Codex 状態は一時的に利用できません"
        case .korean: return "새로고침 실패: Codex 상태를 사용할 수 없습니다"
        case .english: return "Refresh failed: Codex status unavailable"
        }
    }

    public static var resetCreditsCategory: String {
        switch language {
        case .simplifiedChinese: return "Codex 速率限制重置"
        case .traditionalChinese: return "Codex 速率限制重置"
        case .japanese: return "Codex レート制限リセット"
        case .korean: return "Codex 속도 제한 초기화"
        case .english: return "Codex rate-limit resets"
        }
    }

    public static var noResetCredits: String {
        switch language {
        case .simplifiedChinese: return "暂无可显示的重置券"
        case .traditionalChinese: return "暫無可顯示的重置券"
        case .japanese: return "表示できるリセット券はありません"
        case .korean: return "표시할 초기화권이 없습니다"
        case .english: return "No reset credits to show"
        }
    }

    public static var resetCreditsUnavailable: String {
        switch language {
        case .simplifiedChinese: return "暂时无法读取重置券"
        case .traditionalChinese: return "暫時無法讀取重置券"
        case .japanese: return "リセット券を読み込めません"
        case .korean: return "초기화권을 읽을 수 없습니다"
        case .english: return "Reset credits unavailable"
        }
    }

    public static var rateLimitStatusTooltip: String {
        switch language {
        case .simplifiedChinese: return "Codex 限额"
        case .traditionalChinese: return "Codex 限額"
        case .japanese: return "Codex 制限"
        case .korean: return "Codex 한도"
        case .english: return "Codex rate limits"
        }
    }

    public static var localUsageStatusTooltip: String {
        switch language {
        case .simplifiedChinese: return "Codex 本机 token 用量"
        case .traditionalChinese: return "Codex 本機 token 用量"
        case .japanese: return "Codex ローカル token 使用量"
        case .korean: return "Codex 로컬 token 사용량"
        case .english: return "Codex local token usage"
        }
    }

    public static var rateLimitRefreshFailedTooltip: String {
        switch language {
        case .simplifiedChinese: return "Codex 限额刷新失败；显示上次结果"
        case .traditionalChinese: return "Codex 限額重新整理失敗；顯示上次結果"
        case .japanese: return "Codex 制限の更新に失敗しました。前回の結果を表示しています"
        case .korean: return "Codex 한도 새로고침 실패; 마지막 결과 표시 중"
        case .english: return "Codex rate limit refresh failed; showing last value"
        }
    }

    public static var localUsageRefreshFailedTooltip: String {
        switch language {
        case .simplifiedChinese: return "Codex 本机用量刷新失败；显示上次结果"
        case .traditionalChinese: return "Codex 本機用量重新整理失敗；顯示上次結果"
        case .japanese: return "Codex ローカル使用量の更新に失敗しました。前回の結果を表示しています"
        case .korean: return "Codex 로컬 사용량 새로고침 실패; 마지막 결과 표시 중"
        case .english: return "Codex local usage refresh failed; showing last value"
        }
    }

    public static var unknownCategory: String {
        switch language {
        case .simplifiedChinese: return "未知分类"
        case .traditionalChinese: return "未知分類"
        case .japanese: return "不明なカテゴリ"
        case .korean: return "알 수 없는 분류"
        case .english: return "Unknown category"
        }
    }

    public static var unknown: String {
        switch language {
        case .simplifiedChinese, .traditionalChinese: return "未知"
        case .japanese: return "不明"
        case .korean: return "알 수 없음"
        case .english: return "Unknown"
        }
    }

    public static var notSet: String {
        switch language {
        case .simplifiedChinese: return "未设置"
        case .traditionalChinese: return "未設定"
        case .japanese: return "未設定"
        case .korean: return "설정 안 됨"
        case .english: return "Not set"
        }
    }

    public static func availableCount(_ count: Int?) -> String {
        let value = count.map(String.init) ?? "--"
        switch language {
        case .simplifiedChinese: return "可用次数：\(value)"
        case .traditionalChinese: return "可用次數：\(value)"
        case .japanese: return "利用可能：\(value)"
        case .korean: return "사용 가능: \(value)"
        case .english: return "Available: \(value)"
        }
    }

    public static func consumption(_ value: String?) -> String {
        let value = value ?? "--"
        switch language {
        case .simplifiedChinese: return "消耗 \(value)"
        case .traditionalChinese: return "消耗 \(value)"
        case .japanese: return "消費 \(value)"
        case .korean: return "사용 \(value)"
        case .english: return "Used \(value)"
        }
    }

    public static func cacheHit(_ value: String?) -> String {
        let value = value ?? "--"
        switch language {
        case .simplifiedChinese: return "命中 \(value)"
        case .traditionalChinese: return "命中 \(value)"
        case .japanese: return "ヒット \(value)"
        case .korean: return "적중 \(value)"
        case .english: return "Hit \(value)"
        }
    }

    public static func localUsageTooltip(tokens: String, cacheHit: String) -> String {
        switch language {
        case .simplifiedChinese: return "Codex 本机今日 \(tokens)，缓存命中 \(cacheHit)"
        case .traditionalChinese: return "Codex 本機今日 \(tokens)，快取命中 \(cacheHit)"
        case .japanese: return "Codex 今日のローカル使用量 \(tokens)、キャッシュヒット \(cacheHit)"
        case .korean: return "Codex 오늘 로컬 사용량 \(tokens), 캐시 적중 \(cacheHit)"
        case .english: return "Codex local today \(tokens), cache hit \(cacheHit)"
        }
    }

    public static func rateLimitTooltip(weekly: String, resetCount: Int?, forecast: QuotaForecast? = nil) -> String {
        let forecastSuffix = forecast.map { "\n\(quotaForecastLabel($0))" } ?? ""
        switch language {
        case .simplifiedChinese:
            let suffix = resetCount.map { "，重置券 \($0)" } ?? ""
            return "Codex 1 周 \(weekly)\(suffix)\(forecastSuffix)"
        case .traditionalChinese:
            let suffix = resetCount.map { "，重置券 \($0)" } ?? ""
            return "Codex 1 週 \(weekly)\(suffix)\(forecastSuffix)"
        case .japanese:
            let suffix = resetCount.map { "、リセット券 \($0)" } ?? ""
            return "Codex 1週間 \(weekly)\(suffix)\(forecastSuffix)"
        case .korean:
            let suffix = resetCount.map { ", 초기화권 \($0)" } ?? ""
            return "Codex 1주 \(weekly)\(suffix)\(forecastSuffix)"
        case .english:
            let suffix = resetCount.map { ", resets \($0)" } ?? ""
            return "Codex week \(weekly)\(suffix)\(forecastSuffix)"
        }
    }

    public static func quotaForecastLabel(_ forecast: QuotaForecast) -> String {
        switch forecast.status {
        case .exhausted:
            switch language {
            case .simplifiedChinese: return "额度已用尽"
            case .traditionalChinese: return "額度已用盡"
            case .japanese: return "上限に達しました"
            case .korean: return "한도를 모두 사용했습니다"
            case .english: return "Quota exhausted"
            }
        case .insufficientData:
            switch language {
            case .simplifiedChinese: return "正在积累数据以预测消耗"
            case .traditionalChinese: return "正在累積資料以預測消耗"
            case .japanese: return "予測用のデータを収集中"
            case .korean: return "소진 예측 데이터를 수집 중"
            case .english: return "Learning your usage pace"
            }
        case .atRisk:
            guard let exhaustionAt = forecast.projectedExhaustionAt else {
                return quotaForecastAtRiskFallback
            }
            let date = resetDisplay(exhaustionAt, includeDate: true)
            switch language {
            case .simplifiedChinese: return "按当前速度，预计 \(date) 耗尽"
            case .traditionalChinese: return "依目前速度，預計 \(date) 用盡"
            case .japanese: return "現在のペースでは \(date) に上限到達の見込み"
            case .korean: return "현재 속도라면 \(date) 소진 예상"
            case .english: return "At this pace, exhausted by \(date)"
            }
        case .onPace:
            guard let projected = forecast.projectedRemainingAtReset else {
                return quotaForecastOnPaceFallback
            }
            let percent = Int(projected.rounded())
            switch language {
            case .simplifiedChinese: return "消耗正常，重置时预计剩余 \(percent)%"
            case .traditionalChinese: return "消耗正常，重置時預計剩餘 \(percent)%"
            case .japanese: return "順調です。リセット時に \(percent)% 残る見込み"
            case .korean: return "정상 속도, 초기화 시 \(percent)% 남을 예정"
            case .english: return "On pace, about \(percent)% left at reset"
            }
        }
    }

    public static func quotaAlertTitle(_ event: QuotaAlertEvent) -> String {
        switch event.kind {
        case .warning:
            switch language {
            case .simplifiedChinese: return "Codex 周限额剩余 \(event.remainingPercent)%"
            case .traditionalChinese: return "Codex 週限額剩餘 \(event.remainingPercent)%"
            case .japanese: return "Codex 週間上限の残り \(event.remainingPercent)%"
            case .korean: return "Codex 주간 한도 \(event.remainingPercent)% 남음"
            case .english: return "Codex weekly quota: \(event.remainingPercent)% left"
            }
        case .critical:
            switch language {
            case .simplifiedChinese: return "Codex 周限额即将用尽"
            case .traditionalChinese: return "Codex 週限額即將用盡"
            case .japanese: return "Codex 週間上限が残りわずかです"
            case .korean: return "Codex 주간 한도가 거의 소진됨"
            case .english: return "Codex weekly quota is almost exhausted"
            }
        case .projectedExhaustion:
            switch language {
            case .simplifiedChinese: return "Codex 周限额可能提前用尽"
            case .traditionalChinese: return "Codex 週限額可能提前用盡"
            case .japanese: return "Codex 週間上限に早く達する見込みです"
            case .korean: return "Codex 주간 한도가 일찍 소진될 수 있음"
            case .english: return "Codex weekly quota may run out early"
            }
        case .reset:
            switch language {
            case .simplifiedChinese: return "Codex 周限额已重置"
            case .traditionalChinese: return "Codex 週限額已重置"
            case .japanese: return "Codex 週間上限がリセットされました"
            case .korean: return "Codex 주간 한도가 초기화됨"
            case .english: return "Codex weekly quota reset"
            }
        }
    }

    public static func quotaAlertBody(_ event: QuotaAlertEvent) -> String {
        if let exhaustionAt = event.projectedExhaustionAt, event.kind != .reset {
            let date = resetDisplay(exhaustionAt, includeDate: true)
            switch language {
            case .simplifiedChinese: return "当前剩余 \(event.remainingPercent)%，按近期速度预计 \(date) 耗尽。"
            case .traditionalChinese: return "目前剩餘 \(event.remainingPercent)%，依近期速度預計 \(date) 用盡。"
            case .japanese: return "残り \(event.remainingPercent)%です。最近のペースでは \(date) に上限到達の見込みです。"
            case .korean: return "현재 \(event.remainingPercent)% 남음. 최근 속도라면 \(date) 소진 예상입니다."
            case .english: return "\(event.remainingPercent)% remains; recent usage projects exhaustion by \(date)."
            }
        }

        let reset = resetDisplay(event.resetAt, includeDate: true)
        switch event.kind {
        case .warning, .critical, .projectedExhaustion:
            switch language {
            case .simplifiedChinese: return "当前剩余 \(event.remainingPercent)%，将在 \(reset) 重置。"
            case .traditionalChinese: return "目前剩餘 \(event.remainingPercent)%，將於 \(reset) 重置。"
            case .japanese: return "残り \(event.remainingPercent)%です。\(reset) にリセットされます。"
            case .korean: return "현재 \(event.remainingPercent)% 남음. \(reset)에 초기화됩니다."
            case .english: return "\(event.remainingPercent)% remains and resets \(reset)."
            }
        case .reset:
            switch language {
            case .simplifiedChinese: return "新一轮周限额已经开始。"
            case .traditionalChinese: return "新一輪週限額已經開始。"
            case .japanese: return "新しい週間上限期間が始まりました。"
            case .korean: return "새 주간 한도 기간이 시작되었습니다."
            case .english: return "A new weekly quota window has started."
            }
        }
    }

    private static var quotaForecastAtRiskFallback: String {
        switch language {
        case .simplifiedChinese: return "当前消耗速度可能提前用尽额度"
        case .traditionalChinese: return "目前消耗速度可能提前用盡額度"
        case .japanese: return "現在のペースでは早く上限に達する見込み"
        case .korean: return "현재 속도라면 한도가 일찍 소진될 수 있음"
        case .english: return "Current pace may exhaust quota early"
        }
    }

    private static var quotaForecastOnPaceFallback: String {
        switch language {
        case .simplifiedChinese: return "当前消耗速度正常"
        case .traditionalChinese: return "目前消耗速度正常"
        case .japanese: return "現在の利用ペースは順調です"
        case .korean: return "현재 사용 속도는 정상입니다"
        case .english: return "Current usage is on pace"
        }
    }

    public static func localUsageDetail(events: Int, filesWithEvents: Int, filesScanned: Int) -> String {
        switch language {
        case .simplifiedChinese: return "事件 \(events) · 文件 \(filesWithEvents)/\(filesScanned)"
        case .traditionalChinese: return "事件 \(events) · 檔案 \(filesWithEvents)/\(filesScanned)"
        case .japanese: return "イベント \(events) · ファイル \(filesWithEvents)/\(filesScanned)"
        case .korean: return "이벤트 \(events) · 파일 \(filesWithEvents)/\(filesScanned)"
        case .english: return "Events \(events) · Files \(filesWithEvents)/\(filesScanned)"
        }
    }

    public static func resetCreditDetail(index: Int, status: String?, expiresAt: String?) -> String {
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

    public static func resetCreditTypeLabel(_ value: String?) -> String {
        switch value {
        case "codex_rate_limits":
            return resetCreditsCategory
        case let value? where !value.isEmpty:
            return value
        default:
            return unknownCategory
        }
    }

    public static func resetCreditStatusLabel(_ value: String?) -> String {
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

    public static func resetDateTime(_ iso: String?, short: Bool) -> String {
        guard let date = parseIsoDate(iso) else { return notSet }
        let formatter = DateFormatter()
        formatter.locale = systemFormatLocale
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(short ? "MMMdjm" : "yyyyMMMdjmss")
        return formatter.string(from: date)
    }

    public static func resetDisplay(_ date: Date, includeDate: Bool) -> String {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        let display = DateFormatter()
        display.locale = systemFormatLocale
        display.timeZone = .autoupdatingCurrent
        if includeDate || !calendar.isDateInToday(date) {
            display.setLocalizedDateFormatFromTemplate(
                calendar.component(.year, from: date) == calendar.component(.year, from: Date()) ? "MMMdjm" : "yyyyMMMdjm"
            )
        } else {
            display.setLocalizedDateFormatFromTemplate("jm")
        }
        return display.string(from: date)
    }

    public static func statusBarResetDate(_ date: Date) -> String {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        let formatter = DateFormatter()
        formatter.locale = systemFormatLocale
        formatter.timeZone = .autoupdatingCurrent
        let template: String
        if calendar.isDateInToday(date) {
            template = "jm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            template = "MMMd"
        } else {
            template = "yyyyMMMd"
        }
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private static var systemFormatLocale: Locale {
        let globalDefaults = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        if let identifier = globalDefaults?["AppleLocale"] as? String, !identifier.isEmpty {
            return Locale(identifier: identifier)
        }
        return .autoupdatingCurrent
    }

    private static var language: Language {
        let preferred = Locale.preferredLanguages.first ?? Locale.autoupdatingCurrent.identifier
        return language(for: preferred)
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
