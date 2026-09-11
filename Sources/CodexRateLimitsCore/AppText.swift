import Foundation

public enum AppText {
    public static func scanStatus(_ diagnostics: UsageScanDiagnostics?) -> String {
        guard let diagnostics else { return localUsageStatusTooltip }
        switch language {
        case .simplifiedChinese:
            switch diagnostics.status {
            case .complete: return "扫描完整"
            case .empty: return "暂无会话日志"
            case .noUsage: return "暂无今日用量记录"
            case .partial: return "统计不完整 · 已保留可用数据"
            case .unavailable: return "统计不可用 · 无法确认用量"
            }
        case .traditionalChinese:
            switch diagnostics.status {
            case .complete: return "掃描完整"
            case .empty: return "暫無會話日誌"
            case .noUsage: return "暫無今日用量記錄"
            case .partial: return "統計不完整 · 已保留可用資料"
            case .unavailable: return "統計不可用 · 無法確認用量"
            }
        case .japanese:
            switch diagnostics.status {
            case .complete: return "スキャン完了"
            case .empty: return "セッションログなし"
            case .noUsage: return "本日の使用記録なし"
            case .partial: return "統計は不完全 · 取得済みデータを保持"
            case .unavailable: return "統計を取得できません"
            }
        case .korean:
            switch diagnostics.status {
            case .complete: return "스캔 완료"
            case .empty: return "세션 로그 없음"
            case .noUsage: return "오늘 사용 기록 없음"
            case .partial: return "불완전한 통계 · 확인된 데이터 유지"
            case .unavailable: return "사용량을 확인할 수 없음"
            }
        case .english:
            switch diagnostics.status {
            case .complete: return "Scan complete"
            case .empty: return "No session logs"
            case .noUsage: return "No usage records today"
            case .partial: return "Statistics incomplete · available data retained"
            case .unavailable: return "Statistics unavailable · usage unconfirmed"
            }
        }
    }

    public static func billingAssumptions(_ assumptions: UsageBillingAssumptions?) -> String? {
        guard let assumptions, assumptions.totalTokens > 0 else { return nil }
        let values = "API \(CreditFormatter.string(assumptions.apiPercent))% · credits \(CreditFormatter.string(assumptions.creditPercent))%"
        switch language {
        case .simplifiedChinese: return "默认费率占比：\(values)"
        case .traditionalChinese: return "預設費率占比：\(values)"
        case .japanese: return "既定料金を仮定：\(values)"
        case .korean: return "기본 요율 가정: \(values)"
        case .english: return "Assumed pricing: \(values)"
        }
    }

    public static func scanDetails(_ snapshot: LocalUsageSnapshot) -> String {
        let diagnostics = snapshot.diagnostics
        var lines = [scanStatus(diagnostics)]
        if let diagnostics {
            let counts: String
            switch language {
            case .simplifiedChinese: counts = "目录失败 \(diagnostics.directoryFailureCount) · 读取失败 \(diagnostics.readFailureCount) · 文件缺失 \(diagnostics.missingFileCount) · 解析失败 \(diagnostics.parseErrorCount) · 跳过记录 \(diagnostics.skippedRecordCount) · 待写完 \(diagnostics.pendingRecordCount)"
            case .traditionalChinese: counts = "目錄失敗 \(diagnostics.directoryFailureCount) · 讀取失敗 \(diagnostics.readFailureCount) · 檔案缺失 \(diagnostics.missingFileCount) · 解析失敗 \(diagnostics.parseErrorCount) · 跳過記錄 \(diagnostics.skippedRecordCount) · 待寫完 \(diagnostics.pendingRecordCount)"
            case .japanese: counts = "ディレクトリ失敗 \(diagnostics.directoryFailureCount) · 読取失敗 \(diagnostics.readFailureCount) · 欠落 \(diagnostics.missingFileCount) · 解析失敗 \(diagnostics.parseErrorCount) · スキップ \(diagnostics.skippedRecordCount) · 書込待ち \(diagnostics.pendingRecordCount)"
            case .korean: counts = "폴더 오류 \(diagnostics.directoryFailureCount) · 읽기 실패 \(diagnostics.readFailureCount) · 파일 누락 \(diagnostics.missingFileCount) · 파싱 실패 \(diagnostics.parseErrorCount) · 건너뜀 \(diagnostics.skippedRecordCount) · 기록 대기 \(diagnostics.pendingRecordCount)"
            case .english: counts = "Directory failures \(diagnostics.directoryFailureCount) · read failures \(diagnostics.readFailureCount) · missing files \(diagnostics.missingFileCount) · parse failures \(diagnostics.parseErrorCount) · skipped records \(diagnostics.skippedRecordCount) · pending records \(diagnostics.pendingRecordCount)"
            }
            lines.append(counts)
            lines += diagnostics.issues.prefix(8).map { "\($0.path ?? "cache"): \($0.message) (\($0.count))" }
        }
        if let assumptions = snapshot.billingAssumptions {
            if let label = billingAssumptions(assumptions) { lines.append(label) }
            let tier = TokenAmountFormatter.compact(assumptions.missingServiceTierTokens)
            let context = TokenAmountFormatter.compact(assumptions.missingRequestContextTokens)
            switch language {
            case .simplifiedChinese: lines.append("缺少模式：\(tier) tokens；缺少请求上下文：\(context) tokens。两项可能重叠。")
            case .traditionalChinese: lines.append("缺少模式：\(tier) tokens；缺少請求上下文：\(context) tokens。兩項可能重疊。")
            case .japanese: lines.append("モード不明：\(tier) tokens、リクエストコンテキスト不明：\(context) tokens。重複あり。")
            case .korean: lines.append("모드 누락: \(tier) tokens, 요청 컨텍스트 누락: \(context) tokens. 중복 가능.")
            case .english: lines.append("Missing mode: \(tier) tokens; missing request context: \(context) tokens. Counts may overlap.")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static var rebuildLocalUsage: String {
        switch language {
        case .simplifiedChinese: return "重建本机统计"
        case .traditionalChinese: return "重建本機統計"
        case .japanese: return "ローカル統計を再構築"
        case .korean: return "로컬 통계 다시 계산"
        case .english: return "Rebuild Local Usage"
        }
    }

    public static var rebuildLocalUsageDetail: String {
        switch language {
        case .simplifiedChinese: return "重新读取今日及保留的近 8 天会话，重算用量和等价金额，保留有效的账户与周观察基线。"
        case .traditionalChinese: return "重新讀取今日及保留的近 8 天會話，重算用量與等價金額，保留有效的帳戶及週觀察基線。"
        case .japanese: return "今日と保持された過去 8 日間のログを再読込します。アカウントと有効な週間観測の基準は保持されます。"
        case .korean: return "오늘 및 보관된 최근 8일간의 로그를 다시 읽습니다. 계정과 유효한 주간 관측 기준은 유지됩니다."
        case .english: return "Replay today’s and retained eight-day session logs. Preserve the account and valid weekly observation baseline."
        }
    }

    public static var resetCreditDetailsUnavailable: String {
        switch language {
        case .simplifiedChinese: return "可用数量已确认，暂未提供明细"
        case .traditionalChinese: return "可用數量已確認，暫未提供明細"
        case .japanese: return "利用可能数は確認済みです。詳細は未提供です。"
        case .korean: return "사용 가능 횟수는 확인되었으나 상세 정보가 없습니다."
        case .english: return "Available count confirmed; details not provided."
        }
    }

    public static func accountSource(_ context: CodexAccountContext?) -> String {
        let label = context?.accountLabel ?? context.map { URL(fileURLWithPath: $0.codexHome).lastPathComponent } ?? "--"
        let unknown = context?.scopeKey == nil
        switch language {
        case .simplifiedChinese: return "账户：\(label)\(unknown ? " · 身份未确认" : "")"
        case .traditionalChinese: return "帳戶：\(label)\(unknown ? " · 身分未確認" : "")"
        case .japanese: return "アカウント：\(label)\(unknown ? " · 未確認" : "")"
        case .korean: return "계정: \(label)\(unknown ? " · 미확인" : "")"
        case .english: return "Account: \(label)\(unknown ? " · identity unconfirmed" : "")"
        }
    }

    public static func accountSourceDetail(_ context: CodexAccountContext?) -> String {
        guard let context else { return accountSource(nil) }
        let scope: String
        switch language {
        case .simplifiedChinese: scope = "额度、余额和重置次数属于此账户；今日用量为本机所有来源合计。"
        case .traditionalChinese: scope = "額度、餘額與重置次數屬於此帳戶；今日用量為本機所有來源合計。"
        case .japanese: scope = "上限・残高・リセットはこのアカウントの値です。今日の使用量はこの Mac 全体の合計です。"
        case .korean: scope = "한도, 잔액, 초기화 횟수는 이 계정 기준입니다. 오늘 사용량은 이 Mac 전체의 합계입니다."
        case .english: scope = "Quota, balance and resets belong to this account. Today’s usage totals all local sources."
        }
        return "\(accountSource(context))\n\(scope)\nCodex home: \(context.codexHome)\nAuth: \(context.authenticationSource)\nLimit: \(context.limitID)"
    }

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

    public static func todayEstimatedCostCardTitle(requests: Int) -> String {
        switch language {
        case .simplifiedChinese: return "API 等价 · \(requests) 次"
        case .traditionalChinese: return "API 等價 · \(requests) 次"
        case .japanese: return "API 相当 · \(requests)件"
        case .korean: return "API 상당 · \(requests)회"
        case .english: return "API equiv. · \(requests)"
        }
    }

    public static func todayEstimatedCost(_ estimate: UsageCostEstimate?) -> String {
        guard let estimate, let amount = estimate.estimatedCostUSD else {
            switch language {
            case .simplifiedChinese: return "今日 API 等价金额暂不可估算"
            case .traditionalChinese: return "今日 API 等價金額暫無法估算"
            case .japanese: return "今日の API 相当額は推定できません"
            case .korean: return "오늘 API 상당 금액을 추정할 수 없음"
            case .english: return "Today's API-equivalent cost is unavailable"
            }
        }
        let value = USDFormatter.string(amount)
        if estimate.isPartial {
            switch language {
            case .simplifiedChinese: return "今日已知部分约 \(value)"
            case .traditionalChinese: return "今日已知部分約 \(value)"
            case .japanese: return "今日の既知分は約 \(value)"
            case .korean: return "오늘 확인된 부분 약 \(value)"
            case .english: return "Known usage today about \(value)"
            }
        }
        switch language {
        case .simplifiedChinese: return "今日 API 等价约 \(value)"
        case .traditionalChinese: return "今日 API 等價約 \(value)"
        case .japanese: return "今日の API 相当額は約 \(value)"
        case .korean: return "오늘 API 상당 금액 약 \(value)"
        case .english: return "API equivalent today about \(value)"
        }
    }

    public static func weeklyQuotaEstimatedCost(_ estimate: WeeklyQuotaCostEstimate?) -> String {
        if let valuation = estimate?.valuation {
            if valuation.status == .ready, let lower = valuation.lowerUSD, let upper = valuation.upperUSD {
                let range = weeklyValueRange(lower: lower, upper: upper)
                return weeklyText("本机周额度 API 等价 \(range)", "本機週額度 API 等價 \(range)",
                                  "ローカル週間 API 相当額 \(range)", "로컬 주간 API 상당액 \(range)", "Local weekly API equivalent \(range)")
            }
            let reason = weeklyValuationReason(valuation.reason)
            if valuation.status == .collecting {
                return weeklyText("周金额观察中 · \(reason)", "週金額觀察中 · \(reason)", "週間金額を観測中 · \(reason)",
                                  "주간 금액 관측 중 · \(reason)", "Learning weekly value · \(reason)")
            }
            return weeklyText("周金额暂停 · \(reason)", "週金額暫停 · \(reason)", "週間金額の推定停止 · \(reason)",
                              "주간 금액 추정 중지 · \(reason)", "Weekly estimate paused · \(reason)")
        }
        if let reason = estimate?.inferencePauseReason {
            let scan = reason == "incompleteScan"
            switch language {
            case .simplifiedChinese: return scan ? "周金额暂停推算 · 统计不完整" : "周金额暂停推算 · 计费条件缺失"
            case .traditionalChinese: return scan ? "週金額暫停推算 · 統計不完整" : "週金額暫停推算 · 計費條件缺失"
            case .japanese: return scan ? "週間金額の推定を停止 · 不完全な統計" : "週間金額の推定を停止 · 料金情報不足"
            case .korean: return scan ? "주간 금액 추정 중지 · 불완전한 통계" : "주간 금액 추정 중지 · 요율 정보 누락"
            case .english: return scan ? "Weekly estimate paused · incomplete scan" : "Weekly estimate paused · billing assumptions"
            }
        }
        guard let estimate else {
            switch language {
            case .simplifiedChinese: return "正在计算周额度金额"
            case .traditionalChinese: return "正在計算週額度金額"
            case .japanese: return "週間上限の金額を計算中"
            case .korean: return "주간 한도 금액 계산 중"
            case .english: return "Calculating weekly quota value"
            }
        }
        guard let amount = estimate.estimatedQuotaUSD else {
            if estimate.unpricedTokens > 0 && estimate.coveragePercent < 95 {
                let coverage = CreditFormatter.string(estimate.coveragePercent)
                switch language {
                case .simplifiedChinese: return "周金额待补价 · 覆盖 \(coverage)%"
                case .traditionalChinese: return "週金額待補價 · 覆蓋 \(coverage)%"
                case .japanese: return "週間金額の価格不足 · \(coverage)%"
                case .korean: return "주간 금액 가격 누락 · \(coverage)%"
                case .english: return "Weekly prices incomplete · \(coverage)% covered"
                }
            }
            switch language {
            case .simplifiedChinese: return "正在积累周额度金额样本"
            case .traditionalChinese: return "正在累積週額度金額樣本"
            case .japanese: return "週間上限の金額サンプルを収集中"
            case .korean: return "주간 한도 금액 표본 수집 중"
            case .english: return "Learning weekly quota value"
            }
        }
        let value = USDFormatter.string(amount)
        switch language {
        case .simplifiedChinese: return "本机推算周额度约 \(value)"
        case .traditionalChinese: return "本機推算週額度約 \(value)"
        case .japanese: return "ローカル推定の週間上限は約 \(value)"
        case .korean: return "로컬 추정 주간 한도 약 \(value)"
        case .english: return "Local weekly quota estimate about \(value)"
        }
    }

    public static func weeklyValuationSummary(_ value: WeeklyQuotaValuation?) -> String {
        guard let value else { return "" }
        let confidence: String
        switch value.confidence {
        case .low: confidence = weeklyText("低", "低", "低", "낮음", "low")
        case .medium: confidence = weeklyText("中", "中", "中", "보통", "medium")
        case .high: confidence = weeklyText("高", "高", "高", "높음", "high")
        }
        let span = value.observationSpanSeconds >= 3600
            ? String(format: "%.1f h", value.observationSpanSeconds / 3600) : "\(Int(value.observationSpanSeconds / 60)) min"
        return weeklyText("样本置信度\(confidence) · \(value.effectiveIntervalCount) 区间 · \(span)",
                          "樣本信心度\(confidence) · \(value.effectiveIntervalCount) 區間 · \(span)",
                          "標本の信頼度 \(confidence) · \(value.effectiveIntervalCount) 区間 · \(span)",
                          "표본 신뢰도 \(confidence) · \(value.effectiveIntervalCount) 구간 · \(span)",
                          "Sample confidence \(confidence) · \(value.effectiveIntervalCount) intervals · \(span)")
    }

    public static func weeklyValuationDetails(_ value: WeeklyQuotaValuation?) -> String {
        guard let value else { return "" }
        var lines = [weeklyValuationSummary(value)]
        lines.append(weeklyText("官方样本 \(value.sampleCount) 次；排除 \(value.rejectedIntervalCount) 区间；有效额度变化 \(value.effectiveUsedPercent) 个百分点。",
                                "官方樣本 \(value.sampleCount) 次；排除 \(value.rejectedIntervalCount) 區間；有效額度變化 \(value.effectiveUsedPercent) 個百分點。",
                                "公式標本 \(value.sampleCount) 回、除外 \(value.rejectedIntervalCount) 区間、有効変化 \(value.effectiveUsedPercent) ポイント。",
                                "공식 표본 \(value.sampleCount)개, 제외 \(value.rejectedIntervalCount)구간, 유효 한도 변화 \(value.effectiveUsedPercent)%p.",
                                "\(value.sampleCount) official samples; \(value.rejectedIntervalCount) intervals excluded; \(value.effectiveUsedPercent) effective percentage points."))
        if let start = value.sampleStartIso, let end = value.sampleEndIso { lines.append("\(start) → \(end)") }
        if value.creditAssumptionsPresent {
            lines.append(weeklyText("部分 credits 计费条件不明，样本置信度最高为中。", "部分 credits 計費條件不明，樣本信心度最高為中。",
                                    "credits 料金条件に不明点があり、信頼度は最大「中」です。", "일부 credits 요율 조건 누락으로 신뢰도는 보통 이하입니다.",
                                    "Some credit billing conditions are uncertain; sample confidence is capped at medium."))
        }
        lines.append(weeklyText("范围反映本机区间差异及时间对齐误差，并非统计置信区间；其他设备、云端用量不在本机金额内。",
                                "範圍反映本機區間差異及時間對齊誤差，並非統計信賴區間；其他裝置、雲端用量不在本機金額內。",
                                "範囲はローカル区間差と時刻誤差を表し、統計的信頼区間ではありません。他端末・クラウドは対象外です。",
                                "범위는 로컬 구간 차이와 시간 오차를 반영하며 통계적 신뢰구간이 아닙니다. 다른 기기와 클라우드는 제외됩니다.",
                                "The range reflects local interval variation and timing uncertainty, not a statistical confidence interval. Other devices and cloud costs are excluded."))
        return lines.joined(separator: "\n")
    }

    static func weeklyValueRange(lower: Double, upper: Double) -> String {
        guard lower.isFinite, upper.isFinite, lower >= 0, upper >= lower, upper > 0 else { return "--" }
        if upper < 0.01 { return "<$0.01" }
        let step = max(0.01, pow(10, floor(log10(upper)) - 1))
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = min(2, max(0, -Int(floor(log10(step)))))
        let low = floor(lower / step) * step, high = ceil(upper / step) * step
        return "$\(formatter.string(from: NSNumber(value: low)) ?? "--")–$\(formatter.string(from: NSNumber(value: high)) ?? "--")"
    }

    private static func weeklyValuationReason(_ reason: String?) -> String {
        switch reason {
        case "incompleteScan": return weeklyText("统计不完整", "統計不完整", "不完全な統計", "불완전한 통계", "incomplete scan")
        case "billingAssumptions": return weeklyText("API 计费条件缺失", "API 計費條件缺失", "API 料金条件が不足", "API 요율 조건 누락", "API billing assumptions")
        case "unpricedUsage": return weeklyText("存在未知 API 价格", "存在未知 API 價格", "不明な API 価格", "알 수 없는 API 가격", "unknown API prices")
        case "staleQuota": return weeklyText("额度样本已过期", "額度樣本已過期", "上限標本が古い", "한도 표본 만료", "quota sample expired")
        case "quotaTimestampUnavailable": return weeklyText("缺少额度采样时间", "缺少額度取樣時間", "上限の取得時刻が不明", "한도 표본 시간 누락", "missing quota timestamp")
        case "supersededSample": return weeklyText("等待最新额度样本", "等待最新額度樣本", "最新の上限標本を待機", "최신 한도 표본 대기", "waiting for latest quota sample")
        case "samplingGap": return weeklyText("采样中断，重新积累", "取樣中斷，重新累積", "標本の中断後に再学習", "표본 중단 후 다시 수집", "relearning after a sampling gap")
        case "quotaRegression": return weeklyText("额度回退，重新积累", "額度回退，重新累積", "上限の戻り後に再学習", "한도 감소 후 다시 수집", "relearning after quota regression")
        case "quotaExhausted": return weeklyText("额度已耗尽", "額度已耗盡", "上限に到達", "한도 소진", "quota exhausted")
        case "noLocalUsage": return weeklyText("额度与本机用量不匹配", "額度與本機用量不符", "上限とローカル使用量が不一致", "한도와 로컬 사용량 불일치", "quota/local usage mismatch")
        case "alignmentUncertain": return weeklyText("时间边界误差过大", "時間邊界誤差過大", "時刻境界の誤差が大きい", "시간 경계 오차가 큼", "timing uncertainty too large")
        case "unstableSamples": return weeklyText("区间波动过大", "區間波動過大", "区間の変動が大きい", "구간 변동이 큼", "intervals vary too much")
        case "insufficientDuration": return weeklyText("观察时间不足", "觀察時間不足", "観測時間が不足", "관측 시간 부족", "observation too short")
        case "insufficientSignal": return weeklyText("额度变化不足", "額度變化不足", "上限変化が不足", "한도 변화 부족", "quota change too small")
        case "aligningSamples": return weeklyText("正在对齐样本", "正在對齊樣本", "標本時刻を調整中", "표본 시간 정렬 중", "aligning samples")
        default: return weeklyText("有效区间不足", "有效區間不足", "有効区間が不足", "유효 구간 부족", "not enough valid intervals")
        }
    }

    private static func weeklyText(_ zh: String, _ traditional: String, _ ja: String, _ ko: String, _ en: String) -> String {
        switch language {
        case .simplifiedChinese: return zh
        case .traditionalChinese: return traditional
        case .japanese: return ja
        case .korean: return ko
        case .english: return en
        }
    }

    public static var costEstimateDisclaimer: String {
        switch language {
        case .simplifiedChinese:
            return "按公开 API 标准价格估算，并非实际账单。周额度金额由本机观察期间的金额和额度变化反推，跨设备或云端用量会影响准确性。"
        case .traditionalChinese:
            return "依公開 API 標準價格估算，並非實際帳單。週額度金額由本機觀察期間的金額與額度變化反推，跨裝置或雲端用量會影響準確性。"
        case .japanese:
            return "公開 API の標準価格による概算で、実際の請求額ではありません。週間上限額は観測期間のローカル使用額と消費率の変化から推定され、他端末やクラウドの使用により精度が変わります。"
        case .korean:
            return "공개 API 표준 가격 기준 추정치이며 실제 청구액이 아닙니다. 주간 한도 금액은 관찰 기간의 로컬 금액과 사용률 변화로 역산하므로 다른 기기나 클라우드 사용량에 따라 정확도가 달라집니다."
        case .english:
            return "Estimated from public standard API prices, not an actual bill. Weekly value is inferred from this Mac's cost and quota change during the observation period; other devices or cloud usage reduce accuracy."
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

    public static func localUsageTooltip(tokens: String, cacheHit: String, estimatedCost: String? = nil) -> String {
        let costSuffix = estimatedCost.map { "\n\($0)\n\(costEstimateDisclaimer)" } ?? ""
        switch language {
        case .simplifiedChinese: return "Codex 本机今日 \(tokens)，缓存命中 \(cacheHit)\(costSuffix)"
        case .traditionalChinese: return "Codex 本機今日 \(tokens)，快取命中 \(cacheHit)\(costSuffix)"
        case .japanese: return "Codex 今日のローカル使用量 \(tokens)、キャッシュヒット \(cacheHit)\(costSuffix)"
        case .korean: return "Codex 오늘 로컬 사용량 \(tokens), 캐시 적중 \(cacheHit)\(costSuffix)"
        case .english: return "Codex local today \(tokens), cache hit \(cacheHit)\(costSuffix)"
        }
    }

    public static func rateLimitTooltip(
        weekly: String,
        resetCount: Int?,
        forecast: QuotaForecast? = nil,
        weeklyQuotaCost: WeeklyQuotaCostEstimate? = nil
    ) -> String {
        let forecastSuffix = forecast.map { "\n\(quotaForecastLabel($0))" } ?? ""
        let costSuffix = weeklyQuotaCost.map {
            "\n\(weeklyQuotaEstimatedCost($0))\n\(weeklyValuationDetails($0.valuation))\n\(costEstimateDisclaimer)"
                + (unpricedUsageDetails($0.unpricedUsage).map { "\n" + $0 } ?? "")
        } ?? ""
        switch language {
        case .simplifiedChinese:
            let suffix = resetCount.map { "，重置券 \($0)" } ?? ""
            return "Codex 1 周 \(weekly)\(suffix)\(forecastSuffix)\(costSuffix)"
        case .traditionalChinese:
            let suffix = resetCount.map { "，重置券 \($0)" } ?? ""
            return "Codex 1 週 \(weekly)\(suffix)\(forecastSuffix)\(costSuffix)"
        case .japanese:
            let suffix = resetCount.map { "、リセット券 \($0)" } ?? ""
            return "Codex 1週間 \(weekly)\(suffix)\(forecastSuffix)\(costSuffix)"
        case .korean:
            let suffix = resetCount.map { ", 초기화권 \($0)" } ?? ""
            return "Codex 1주 \(weekly)\(suffix)\(forecastSuffix)\(costSuffix)"
        case .english:
            let suffix = resetCount.map { ", resets \($0)" } ?? ""
            return "Codex week \(weekly)\(suffix)\(forecastSuffix)\(costSuffix)"
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


extension AppText {
    public static func pricingVersion(_ pricing: UsagePricingMetadata?) -> String {
        guard let pricing else { return "" }
        let origin = pricing.source == "custom"
            ? weeklyText("自定义", "自訂", "カスタム", "사용자 정의", "custom")
            : weeklyText("内置", "內建", "組み込み", "기본", "built-in")
        let versions = pricing.api.version == pricing.credits.version ? pricing.api.version
            : "API \(pricing.api.version) / credits \(pricing.credits.version)"
        let prefix = weeklyText("价目表", "價目表", "料金表", "요금표", "Rate card")
        return "\(prefix) \(versions) · \(origin)" + (pricing.configurationError == nil ? "" : " ⚠︎")
    }

    public static func pricingDetails(_ pricing: UsagePricingMetadata?) -> String {
        guard let pricing else { return "" }
        let verified = weeklyText("核验", "核驗", "確認", "확인", "verified")
        var lines = [pricingVersion(pricing), "API \(verified): \(pricing.api.verifiedAt) · credits \(verified): \(pricing.credits.verifiedAt)",
            weeklyText("历史用量按当前价目表重估；自定义配置中的日期与来源由用户声明。", "歷史用量依目前價目表重估；自訂配置中的日期與來源由使用者聲明。",
                       "履歴は現在の料金表で再計算。カスタムの日付と出典は利用者による申告です。", "과거 사용량은 현재 요율로 재평가하며 사용자 설정 날짜와 출처는 사용자 선언입니다.",
                       "Historical usage is re-estimated at current rates. Custom verification dates and sources are user-declared.")]
        if let oldAPI = pricing.previousAPIVersion, let oldCredits = pricing.previousCreditsVersion, let at = pricing.changedAtIso {
            lines.append("API \(oldAPI) → \(pricing.api.version); credits \(oldCredits) → \(pricing.credits.version) · \(at)")
            lines.append(weeklyText("价目表内容已变更，受影响日志按新规则重算。", "價目表內容已變更，受影響日誌依新規則重算。",
                                   "料金表の変更に伴い、対象ログを再計算。", "요금표 변경으로 영향을 받는 로그를 재계산합니다.", "The rate card changed; affected logs are recalculated with the new rules."))
        }
        if let path = pricing.configurationPath { lines.append(path) }
        if let error = pricing.configurationError { lines.append(error) }
        lines += ["API: " + pricing.api.conditions.joined(separator: " "), "credits: " + pricing.credits.conditions.joined(separator: " ")]
        lines += Array(Set(pricing.api.sources + pricing.credits.sources)).sorted()
        return lines.joined(separator: "\n")
    }

    public static func unpricedUsageDetails(_ entries: [UnpricedUsage]?) -> String? {
        guard let entries, !entries.isEmpty else { return nil }
        return entries.map { entry in
            let reason: String
            switch entry.reason {
            case "unknownModel": reason = weeklyText("未知模型", "未知模型", "不明なモデル", "알 수 없는 모델", "unknown model")
            case "unknownServiceTier": reason = weeklyText("未知模式", "未知模式", "不明なモード", "알 수 없는 모드", "unknown mode")
            case "unsupportedContext": reason = weeklyText("该上下文无价格", "該上下文無價格", "対象コンテキストの価格なし", "컨텍스트 요금 없음", "unpriced context")
            default: reason = weeklyText("等待价格重算", "等待價格重算", "再計算待ち", "요금 재계산 대기", "awaiting repricing")
            }
            let tier = entry.serviceTier.map { " · \($0)" } ?? ""
            return "\(entry.kind) · \(entry.model)\(tier) · \(entry.totalTokens) tokens (\(String(format: "%.2f", entry.percent))%) · \(reason)"
        }.joined(separator: "\n")
    }

    public static func todayEstimatedCredits(_ estimate: UsageCreditEstimate?) -> String {
        let amount = CreditFormatter.string(estimate?.estimatedCredits)
        let value = amount + (estimate?.isPartial == true && estimate?.estimatedCredits != nil ? "+" : "")
        switch language {
        case .simplifiedChinese: return "今日 credits 估算：\(value)"
        case .traditionalChinese: return "今日 credits 估算：\(value)"
        case .japanese: return "今日の推定 credits：\(value)"
        case .korean: return "오늘 credits 추정: \(value)"
        case .english: return "Estimated credits today: \(value)"
        }
    }

    public static func officialCreditsBalance(_ credits: CreditsSnapshot?) -> String {
        let value = credits?.unlimited == true ? "∞"
            : CreditFormatter.string(credits?.balance.flatMap(Double.init))
        switch language {
        case .simplifiedChinese: return "官方 credits 余额：\(value)"
        case .traditionalChinese: return "官方 credits 餘額：\(value)"
        case .japanese: return "公式 credits 残高：\(value)"
        case .korean: return "공식 credits 잔액: \(value)"
        case .english: return "Official credits balance: \(value)"
        }
    }

    public static func pricingCoverage(cost: UsageCostEstimate?, credits: UsageCreditEstimate?) -> String {
        let values = "API \(CreditFormatter.string(cost?.coveragePercent))% · credits \(CreditFormatter.string(credits?.coveragePercent))%"
        switch language {
        case .simplifiedChinese: return "定价覆盖：\(values)"
        case .traditionalChinese: return "定價覆蓋：\(values)"
        case .japanese: return "価格カバー率：\(values)"
        case .korean: return "가격 적용률: \(values)"
        case .english: return "Price coverage: \(values)"
        }
    }

    public static func unpricedModels(cost: UsageCostEstimate?, credits: UsageCreditEstimate?) -> String? {
        let models = Set((cost?.unpricedModels ?? []) + (credits?.unpricedModels ?? [])).sorted()
        guard !models.isEmpty else { return nil }
        let names = models.joined(separator: ", ")
        switch language {
        case .simplifiedChinese: return "未定价模型/模式：\(names)"
        case .traditionalChinese: return "未定價模型/模式：\(names)"
        case .japanese: return "価格不明のモデル/モード：\(names)"
        case .korean: return "가격 미확인 모델/모드: \(names)"
        case .english: return "Unpriced models/modes: \(names)"
        }
    }

    public static var creditsEstimateNote: String {
        switch language {
        case .simplifiedChinese: return "本机用量折算，并非实际扣费"
        case .traditionalChinese: return "本機用量折算，並非實際扣費"
        case .japanese: return "ローカル使用量の換算で、実際の請求ではありません"
        case .korean: return "로컬 사용량 환산이며 실제 청구가 아닙니다"
        case .english: return "Local usage equivalent, not actual credits deducted"
        }
    }

    public static var creditsEstimateDetails: String {
        switch language {
        case .simplifiedChinese: return "按当前 token-based credits 费率估算。套餐内使用不等于扣除购买的 credits；云端、其他设备及工具费用不在本机统计内。缺少模式或单次上下文记录时按标准费率估算，旧版企业费率不适用。"
        case .traditionalChinese: return "依目前 token-based credits 費率估算。方案內使用不等於扣除購買的 credits；雲端、其他裝置及工具費用不在本機統計內。缺少模式或單次上下文記錄時依標準費率估算，舊版企業費率不適用。"
        case .japanese: return "現在のトークンベース credits 料金による概算です。プラン内利用は購入 credits の消費とは異なります。クラウド、他端末、ツール料金は含みません。モードやコンテキスト記録がない場合は標準料金を仮定します。旧企業料金は対象外です。"
        case .korean: return "현재 토큰 기반 credits 요금으로 추정합니다. 플랜 내 사용은 구매 credits 차감과 다릅니다. 클라우드, 다른 기기 및 도구 요금은 제외됩니다. 모드나 컨텍스트 기록이 없으면 표준 요금을 가정합니다. 기존 기업 요금에는 적용되지 않습니다."
        case .english: return "Estimated at current token-based credit rates. Included plan usage is not purchased-credit deduction. Cloud, other devices and tool fees are excluded. Missing mode or per-request context records use standard rates. Legacy Enterprise rates are not covered."
        }
    }

    public static func creditAssumptions(_ estimate: UsageCreditEstimate?) -> String? {
        guard let count = estimate?.assumedStandardTokens, count > 0 else { return nil }
        let tokens = TokenAmountFormatter.compact(count)
        switch language {
        case .simplifiedChinese: return "\(tokens) tokens 缺少模式记录，按标准模式估算"
        case .traditionalChinese: return "\(tokens) tokens 缺少模式記錄，依標準模式估算"
        case .japanese: return "\(tokens) tokens はモード記録がないため標準で推定"
        case .korean: return "\(tokens) tokens: 모드 기록이 없어 표준으로 추정"
        case .english: return "\(tokens) tokens lack a mode record; standard mode assumed"
        }
    }
}
