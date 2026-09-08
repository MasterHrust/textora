import Foundation

enum SecureAITransportPolicy {
    static func allows(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host?.isEmpty == false
            && url.user == nil
            && url.password == nil
    }

    static func redirectedRequest(originalURL: URL?, proposedRequest: URLRequest) -> URLRequest? {
        guard allows(originalURL),
              allows(proposedRequest.url),
              proposedRequest.url?.host?.lowercased() == originalURL?.host?.lowercased(),
              proposedRequest.url?.port == originalURL?.port else { return nil }
        return proposedRequest
    }
}

private final class SecureAIURLSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(SecureAITransportPolicy.redirectedRequest(
            originalURL: task.originalRequest?.url,
            proposedRequest: request
        ))
    }
}

private actor AIRequestDeduplicator {
    static let shared = AIRequestDeduplicator()

    private var stringTasks: [String: Task<String, Error>] = [:]
    private var suggestionTasks: [String: Task<[OverlaySuggestion], Error>] = [:]

    func string(
        key: String,
        operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        if let task = stringTasks[key] {
            return try await task.value
        }
        let task = Task { try await operation() }
        stringTasks[key] = task
        defer { stringTasks[key] = nil }
        return try await task.value
    }

    func suggestions(
        key: String,
        operation: @escaping @Sendable () async throws -> [OverlaySuggestion]
    ) async throws -> [OverlaySuggestion] {
        if let task = suggestionTasks[key] {
            return try await task.value
        }
        let task = Task { try await operation() }
        suggestionTasks[key] = task
        defer { suggestionTasks[key] = nil }
        return try await task.value
    }
}

struct AIClient {
    /// User-configured base URL for OpenAI-compatible Chat Completions (stored in UserDefaults).
    static let openAICompatibleBaseURLUserDefaultsKey = "openAICompatibleBaseURL"
    private static let secureSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: SecureAIURLSessionDelegate(), delegateQueue: nil)
    }()

    private static func secureData(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard SecureAITransportPolicy.allows(request.url) else {
            throw NSError(
                domain: "Textora.Security",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "AI requests require a valid HTTPS endpoint"]
            )
        }
        return try await secureSession.data(for: request)
    }

    enum Defaults {
        static let openAIModel = "gpt-5.4"
        static let geminiModel = "gemini-3.7-flash"
        static let claudeModel = "claude-sonnet-5"
        /// Placeholder model id; your server may use a different id — set **Model** in Settings accordingly.
        static let customModel = "gpt-4o-mini"
    }

    func availableModels(provider: AIProvider, apiKey: String) async throws -> [AIModelOption] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw NSError(
                domain: "Textora",
                code: 19,
                userInfo: [NSLocalizedDescriptionKey: "Add an API key to load models"]
            )
        }

        switch provider {
        case .openai:
            return try await availableOpenAIModels(apiKey: key)
        case .gemini:
            return try await availableGeminiModels(apiKey: key)
        case .claude:
            return try await availableClaudeModels(apiKey: key)
        case .other:
            return []
        }
    }

    private func logAIRequest(
        kind: String,
        provider: AIProvider,
        model: String,
        operation: RewriteOperation?,
        text: String,
        promptKind: String
    ) -> Date {
        let startedAt = Date()
        textoraDiagLog(
            "aiRewrite",
            "request kind=\(kind) provider=\(provider.rawValue) model=\(model) "
            + "operation=\(operation?.rawValue ?? "multi") prompt=\(promptKind) "
            + "textLen=\((text as NSString).length)"
        )
        return startedAt
    }

    private func fallbackModel(for provider: AIProvider) -> String {
        switch provider {
        case .openai:
            return Defaults.openAIModel
        case .gemini:
            return Defaults.geminiModel
        case .claude:
            return Defaults.claudeModel
        case .other:
            return Defaults.customModel
        }
    }

    private func requestCacheKey(
        kind: String,
        provider: AIProvider,
        model: String,
        apiKey: String,
        operation: RewriteOperation?,
        text: String
    ) -> String {
        let baseURL = provider == .other
            ? (UserDefaults.standard.string(forKey: Self.openAICompatibleBaseURLUserDefaultsKey) ?? "")
            : ""
        return [
            kind,
            provider.rawValue,
            model,
            baseURL,
            String(apiKey.hashValue),
            operation?.rawValue ?? "multi",
            text
        ].joined(separator: "\u{1F}")
    }

    private func logAIResponse(
        kind: String,
        startedAt: Date,
        output: String
    ) {
        textoraDiagLog(
            "aiRewrite",
            "response kind=\(kind) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) "
            + "outputLen=\((output as NSString).length)"
        )
    }

    private func logAIResponse(
        kind: String,
        startedAt: Date,
        suggestions: [OverlaySuggestion]
    ) {
        let summary = suggestions
            .map { "\($0.operation.rawValue):\(($0.text as NSString).length)" }
            .joined(separator: ",")
        textoraDiagLog(
            "aiRewrite",
            "response kind=\(kind) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) "
            + "suggestions=\(summary.isEmpty ? "none" : summary)"
        )
    }

    private func logAIResponse(
        kind: String,
        startedAt: Date,
        issues: [OverlayIssue]
    ) {
        let summary = issues
            .map { "\($0.category.rawValue):\($0.localRange.location):\($0.localRange.length)" }
            .joined(separator: ",")
        textoraDiagLog(
            "aiRewrite",
            "response kind=\(kind) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) "
            + "issues=\(summary.isEmpty ? "none" : summary)"
        )
    }

    func rewriteText(
        provider: AIProvider,
        model: String,
        apiKey: String,
        text: String,
        operation: RewriteOperation
    ) async throws -> String {
        let resolvedModel = model.isEmpty ? fallbackModel(for: provider) : model
        let startedAt = logAIRequest(
            kind: "manualRewrite",
            provider: provider,
            model: resolvedModel,
            operation: operation,
            text: text,
            promptKind: "operationPrompt"
        )
        let cacheKey = requestCacheKey(
            kind: "manualRewrite",
            provider: provider,
            model: resolvedModel,
            apiKey: apiKey,
            operation: operation,
            text: text
        )
        let output = try await AIRequestDeduplicator.shared.string(key: cacheKey) {
            switch provider {
            case .openai:
                return try await rewriteOpenAI(
                    model: model.isEmpty ? Defaults.openAIModel : model,
                    apiKey: apiKey,
                    text: text,
                    operation: operation,
                    systemPromptOverride: nil
                )
            case .gemini:
                return try await rewriteGemini(
                    model: model.isEmpty ? Defaults.geminiModel : model,
                    apiKey: apiKey,
                    text: text,
                    operation: operation,
                    systemPromptOverride: nil
                )
            case .claude:
                return try await rewriteClaude(
                    model: model.isEmpty ? Defaults.claudeModel : model,
                    apiKey: apiKey,
                    text: text,
                    operation: operation,
                    systemPromptOverride: nil
                )
            case .other:
                return try await rewriteOpenAICompatible(
                    model: model.isEmpty ? Defaults.customModel : model,
                    token: apiKey,
                    text: text,
                    operation: operation,
                    systemPromptOverride: nil
                )
            }
        }
        logAIResponse(kind: "manualRewrite", startedAt: startedAt, output: output)
        return output
    }

    func checkAndSuggestIfNeeded(
        provider: AIProvider,
        model: String,
        apiKey: String,
        text: String
    ) async throws -> String {
        let resolvedModel = model.isEmpty ? fallbackModel(for: provider) : model
        let startedAt = logAIRequest(
            kind: "fixCheck",
            provider: provider,
            model: resolvedModel,
            operation: .fixGrammar,
            text: text,
            promptKind: "strictFix"
        )
        let strictPrompt = """
        You are a precision grammar assistant.
        Correct grammar, spelling, punctuation, word order, and obvious shorthand while preserving intended meaning.
        Prefer the smallest complete phrase that sounds natural and correct.
        If the phrase is malformed, reorder words when needed.
        Example: "Ar u how?" becomes "How are you?"
        Preserve wording, tone, formatting, and line breaks.
        Do not modify URLs, email addresses, phone numbers, standalone numbers, @mentions, #hashtags, code-like tokens, or words that start with @ or #.
        Do not use em dashes; use commas, periods, colons, or a regular hyphen only when needed.
        If the text is already correct, return the exact original text unchanged.
        Return only the final corrected text.
        """

        let cacheKey = requestCacheKey(
            kind: "fixCheck",
            provider: provider,
            model: resolvedModel,
            apiKey: apiKey,
            operation: .fixGrammar,
            text: text
        )
        let output = try await AIRequestDeduplicator.shared.string(key: cacheKey) {
            switch provider {
            case .openai:
                return try await rewriteOpenAI(
                    model: model.isEmpty ? Defaults.openAIModel : model,
                    apiKey: apiKey,
                    text: text,
                    operation: .fixGrammar,
                    systemPromptOverride: strictPrompt
                )
            case .gemini:
                return try await rewriteGemini(
                    model: model.isEmpty ? Defaults.geminiModel : model,
                    apiKey: apiKey,
                    text: text,
                    operation: .fixGrammar,
                    systemPromptOverride: strictPrompt
                )
            case .claude:
                return try await rewriteClaude(
                    model: model.isEmpty ? Defaults.claudeModel : model,
                    apiKey: apiKey,
                    text: text,
                    operation: .fixGrammar,
                    systemPromptOverride: strictPrompt
                )
            case .other:
                return try await rewriteOpenAICompatible(
                    model: model.isEmpty ? Defaults.customModel : model,
                    token: apiKey,
                    text: text,
                    operation: .fixGrammar,
                    systemPromptOverride: strictPrompt
                )
            }
        }
        logAIResponse(kind: "fixCheck", startedAt: startedAt, output: output)
        return output
    }

    func overlaySuggestions(
        provider: AIProvider,
        model: String,
        apiKey: String,
        text: String
    ) async throws -> [OverlaySuggestion] {
        let resolvedModel = model.isEmpty ? fallbackModel(for: provider) : model
        let startedAt = logAIRequest(
            kind: "overlaySuggestions",
            provider: provider,
            model: resolvedModel,
            operation: nil,
            text: text,
            promptKind: "multiOperationJSON"
        )
        let prompt = """
        You are Textora's inline suggestion engine.
        Return only a compact JSON object with these exact string keys: "fix", "formal", "shorten", "humanize".

        Rules:
        - "fix" corrects grammar, spelling, punctuation, word order, and obvious shorthand while preserving intended meaning. "fix" should use the whole phrase when needed. Example: "Ar u how?" becomes "How are you?"
        - "formal" rewrites the text in a professional, polished tone only when that is clearly useful.
        - "shorten" rewrites the text to be shorter and clearer only when the text is actually verbose.
        - "humanize" rewrites the text to sound natural and conversational only when the text sounds stiff or robotic.
        - For "formal", "shorten", and "humanize", return the original text when a genuinely useful, meaning-preserving rewrite is not available. Do not invent variants for short fragments.
        - Keep the input language unchanged.
        - Preserve line breaks when possible.
        - Preserve ordered-list markers exactly. Never remove or rewrite a leading list number, the dot after it, or the following separator space (for example, keep "1. " intact).
        - Do not modify URLs, email addresses, phone numbers, standalone numbers, @mentions, #hashtags, code-like tokens, or words that start with @ or #.
        - Do not replace a correctly spelled common word with a different correctly spelled word unless the surrounding sentence makes the intended word unambiguous. For short fragments, keep the word unchanged.
        - If the text is a short incomplete clause or fragment (for example starts with "if", "when", "because", "while" and has no main clause), do not guess missing context; keep all keys equal to the original unless there is an obvious spelling typo.
        - Preserve rare, unknown, domain-specific, transliterated, brand-like, product-like, or intentionally informal words unless the correction is obvious from the same word form. If unsure, keep the word unchanged and only fix punctuation/grammar around it.
        - Do NOT "correct" currency abbreviations or unit symbols. Treat them as protected tokens: EUR, USD, GBP, JPY, CHF, CAD, AUD, CNY, RUB, UAH, etc.; €, $, £, ¥, ₽, ₴; %, ‰, kg, g, lb, km, m, cm, mm, ft, in, mph, kph, °C, °F, …
        - Do not use em dashes; use commas, periods, colons, or a regular hyphen only when needed.
        - "fix" must equal the original when no high-confidence grammar/spelling issue exists.
        - No explanations, no markdown, no code block.
        """

        let cacheKey = requestCacheKey(
            kind: "overlaySuggestions",
            provider: provider,
            model: resolvedModel,
            apiKey: apiKey,
            operation: nil,
            text: text
        )
        let suggestions = try await AIRequestDeduplicator.shared.suggestions(key: cacheKey) {
            let raw: String
            switch provider {
            case .openai:
                raw = try await rewriteOpenAI(
                    model: model.isEmpty ? Defaults.openAIModel : model,
                    apiKey: apiKey,
                    text: text,
                    operation: .fixGrammar,
                    systemPromptOverride: prompt
                )
            case .gemini:
                raw = try await rewriteGemini(
                    model: model.isEmpty ? Defaults.geminiModel : model,
                    apiKey: apiKey,
                    text: text,
                    operation: .fixGrammar,
                    systemPromptOverride: prompt
                )
            case .claude:
                raw = try await rewriteClaude(
                    model: model.isEmpty ? Defaults.claudeModel : model,
                    apiKey: apiKey,
                    text: text,
                    operation: .fixGrammar,
                    systemPromptOverride: prompt
                )
            case .other:
                raw = try await rewriteOpenAICompatible(
                    model: model.isEmpty ? Defaults.customModel : model,
                    token: apiKey,
                    text: text,
                    operation: .fixGrammar,
                    systemPromptOverride: prompt
                )
            }
            return decodeOverlaySuggestions(raw, original: text)
        }
        logAIResponse(kind: "overlaySuggestions", startedAt: startedAt, suggestions: suggestions)
        return suggestions
    }

    /// Structured "auditor" pass: the model returns a list of *localized*
    /// issues inside `text`, each tagged with a writing-operation
    /// category (Fix / Formal / Humanize / Shorten) and a replacement
    /// string. The UI renders one underline marker per issue (colored by
    /// category) and the apply pipeline only rewrites the specific span,
    /// not the whole segment — so a single sentence can carry multiple
    /// independently fixable markers of mixed categories.
    ///
    /// The priority rules baked into the prompt come straight from the
    /// product brief:
    ///   - pure grammar / spelling / punctuation mistake → `fix`
    ///   - tone is already correct, message is casual and simple →
    ///     `humanize` (even on otherwise clean text)
    ///   - long informal run with no errors → `shorten`
    ///   - formal register → `formal`
    ///   - mix: `fix` always wins, style suggestions come after
    func auditIssues(
        provider: AIProvider,
        model: String,
        apiKey: String,
        text: String
    ) async throws -> [OverlayIssue] {
        let resolvedModel = model.isEmpty ? fallbackModel(for: provider) : model
        let startedAt = logAIRequest(
            kind: "auditIssues",
            provider: provider,
            model: resolvedModel,
            operation: nil,
            text: text,
            promptKind: "localizedAuditJSON"
        )
        let prompt = """
        You are Textora's inline auditor. You receive a single user text and must
        return a JSON object with one key, "issues", whose value is an array of
        localized edit proposals. Each issue MUST be a JSON object with these
        fields:
          - "id": stable string identifier for this patch. Reuse the same id
            only for the exact same span + replacement.
          - "start": integer, 0-based offset (UTF-16 units, i.e. NSString-style)
            into the input text where the issue begins.
          - "end": integer, exclusive end offset in the same unit system.
          - "originalText": exact substring currently present between
            "start" and "end". Must match the source text exactly.
          - "category": one of "fix", "formal", "humanize", "shorten".
          - "replacement": the exact text that should replace the substring
            between "start" and "end".
          - "reason": short human-readable explanation (max ~8 words). May be
            empty.

        Category semantics:
          - "fix": grammar, spelling, punctuation, word order, obvious
            shorthand. Use the smallest span that produces a natural
            correction. Preserve meaning.
          - "formal": raise register to a professional / polished tone. Use
            only when the surrounding text already reads formal-ish or when
            the user clearly intends a business-style message.
          - "humanize": make wording warmer, more natural, less robotic. Use
            when the text is grammatically correct and short / chatty.
          - "shorten": tighten verbose phrasing. Use when the text is
            grammatically correct and long / repetitive.
          - Preserve ordered-list markers exactly. Never remove or rewrite a
            leading list number, the dot after it, or the following separator
            space (for example, keep "1. " intact).

        Priority rules when multiple categories could apply to the same span:
          - If there is a grammar / spelling / punctuation error, issue a
            "fix" first; style suggestions are added as separate issues on
            different spans if useful.
          - Do NOT emit a "formal", "humanize", or "shorten" issue whose
            span overlaps the span of a "fix" issue. Choose non-overlapping
            spans.
          - Prefer FEWER, higher-signal issues over many small ones. If the
            text is clean and nothing would actually improve the writing,
            return "issues": [].

        Hard constraints:
          - Keep the input language unchanged.
          - Emit a style issue when the replacement is clearly valuable and
            preserves meaning. Prefer a local phrase edit, but if the only
            useful style improvement is sentence-level, the span may cover the
            full sentence/text.
          - Never emit a style issue that only changes sentence-ending
            punctuation or only tweaks one short word/token in isolation.
          - If you are not highly confident that the local replacement
            preserves the sentence's meaning in context, omit the issue.
          - "start" / "end" MUST align with word boundaries when possible and
            MUST lie inside the input text (0 ≤ start < end ≤ length).
          - "originalText" MUST equal the exact substring from the input at
            [start, end). If you are not sure, omit the issue entirely.
          - Do not modify URLs, email addresses, phone numbers, standalone
            numbers, @mentions, #hashtags, code-like tokens, or words that
            start with @ or #.
          - Do NOT "correct" currency abbreviations or unit symbols. Treat
            them as protected tokens: EUR, USD, GBP, JPY, CHF, CAD, AUD,
            CNY, RUB, UAH, etc.; €, $, £, ¥, ₽, ₴; %, ‰, kg, g, lb, km, m,
            cm, mm, ft, in, mph, kph, °C, °F, …
          - Do not use em dashes; use commas, periods, colons, or a regular
            hyphen when needed.
          - "replacement" must NOT duplicate the substring it replaces — if
            you would return the same characters, omit the issue entirely.

        Output:
          - Return only the JSON object. No explanations, no markdown, no
            code fences.
          - Maximum 6 issues per response.
        """

        let raw: String
        switch provider {
        case .openai:
            raw = try await rewriteOpenAI(
                model: model.isEmpty ? Defaults.openAIModel : model,
                apiKey: apiKey,
                text: text,
                operation: .fixGrammar,
                systemPromptOverride: prompt
            )
        case .gemini:
            raw = try await rewriteGemini(
                model: model.isEmpty ? Defaults.geminiModel : model,
                apiKey: apiKey,
                text: text,
                operation: .fixGrammar,
                systemPromptOverride: prompt
            )
        case .claude:
            raw = try await rewriteClaude(
                model: model.isEmpty ? Defaults.claudeModel : model,
                apiKey: apiKey,
                text: text,
                operation: .fixGrammar,
                systemPromptOverride: prompt
            )
        case .other:
            raw = try await rewriteOpenAICompatible(
                model: model.isEmpty ? Defaults.customModel : model,
                token: apiKey,
                text: text,
                operation: .fixGrammar,
                systemPromptOverride: prompt
            )
        }
        let issues = decodeAuditIssues(raw, original: text)
        logAIResponse(kind: "auditIssues", startedAt: startedAt, issues: issues)
        return issues
    }

    func translateText(
        provider: AIProvider,
        model: String,
        apiKey: String,
        text: String,
        targetLanguage: String
    ) async throws -> String {
        func normalized(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .lowercased()
        }

        let lang = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lang.isEmpty else {
            throw NSError(domain: "Textora", code: 20, userInfo: [NSLocalizedDescriptionKey: "Target language is empty"])
        }
        let prompt = """
        You are a translation engine.
        Detect the source language automatically.
        Translate the user text into \(lang).
        Preserve meaning, tone, formatting, and line breaks.
        Return only the translated text. No explanations.
        """

        func run(_ systemPrompt: String) async throws -> String {
            switch provider {
            case .openai:
                return try await rewriteOpenAI(
                    model: model.isEmpty ? Defaults.openAIModel : model,
                    apiKey: apiKey,
                    text: text,
                    operation: .fixGrammar,
                    systemPromptOverride: systemPrompt
                )
            case .gemini:
                return try await rewriteGemini(
                    model: model.isEmpty ? Defaults.geminiModel : model,
                    apiKey: apiKey,
                    text: text,
                    operation: .fixGrammar,
                    systemPromptOverride: systemPrompt
                )
            case .claude:
                return try await rewriteClaude(
                    model: model.isEmpty ? Defaults.claudeModel : model,
                    apiKey: apiKey,
                    text: text,
                    operation: .fixGrammar,
                    systemPromptOverride: systemPrompt
                )
            case .other:
                return try await rewriteOpenAICompatible(
                    model: model.isEmpty ? Defaults.customModel : model,
                    token: apiKey,
                    text: text,
                    operation: .fixGrammar,
                    systemPromptOverride: systemPrompt
                )
            }
        }

        let first = try await run(prompt)
        if normalized(first) != normalized(text) {
            return first
        }

        let retryPrompt = """
        IMPORTANT: Output must be written in \(lang).
        Detect the source language automatically.
        Translate the user text into \(lang).
        Preserve meaning, tone, formatting, and line breaks.
        Return only the translated text. No explanations.
        """
        return try await run(retryPrompt)
    }

    private struct OverlaySuggestionPayload: Decodable {
        let fix: String?
        let formal: String?
        let shorten: String?
        let humanize: String?
    }

    private struct AuditIssuePayload: Decodable {
        let id: String?
        let start: Int
        let end: Int
        let originalText: String
        let category: String
        let replacement: String
        let reason: String?
    }

    private struct AuditIssuesPayload: Decodable {
        let issues: [AuditIssuePayload]
    }

    private func decodeAuditIssues(_ raw: String, original: String) -> [OverlayIssue] {
        guard let json = extractJSONObject(from: raw),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AuditIssuesPayload.self, from: data) else {
            return []
        }
        let ns = original as NSString
        let totalLen = ns.length
        guard totalLen > 0 else { return [] }

        var validated: [OverlayIssue] = []
        for raw in payload.issues {
            guard let category = operationForAuditCategory(raw.category) else { continue }
            let rawStart = raw.start
            let rawEnd = raw.end
            let length = rawEnd - rawStart
            guard rawStart >= 0, rawEnd >= rawStart, rawEnd <= totalLen else { continue }
            guard length > 0 else { continue }
            let localRange = NSRange(location: rawStart, length: length)
            let originalSpan = ns.substring(with: localRange)
            guard originalSpan == raw.originalText else { continue }
            let replacement = raw.replacement
            // Drop null edits.
            if normalizedForSuggestionDedupe(originalSpan) == normalizedForSuggestionDedupe(replacement) {
                continue
            }
            // Ensure the rewrite does not silently drop any protected
            // token that lived inside the span (URLs, currencies, …).
            if !preservesProtectedTokens(original: originalSpan, candidate: replacement) {
                continue
            }
            let trimmedReason = raw.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            validated.append(
                OverlayIssue(
                    patch: TextPatch(
                        id: {
                            let trimmed = raw.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            return trimmed.isEmpty ? UUID().uuidString : trimmed
                        }(),
                        start: rawStart,
                        end: rawEnd,
                        originalText: originalSpan,
                        replacement: replacement,
                        reason: (trimmedReason?.isEmpty == true) ? nil : trimmedReason
                    ),
                    category: category,
                    segmentSignature: nil,
                    sourceSegmentRange: nil
                )
            )
        }

        // Reject issues whose spans overlap: keep the one with the higher
        // priority (Fix wins) and drop the rest to avoid UI ambiguity.
        validated.sort { lhs, rhs in
            if lhs.localRange.location != rhs.localRange.location {
                return lhs.localRange.location < rhs.localRange.location
            }
            return OverlayIssue.priority(of: lhs.category) < OverlayIssue.priority(of: rhs.category)
        }
        var accepted: [OverlayIssue] = []
        for issue in validated {
            if let last = accepted.last, NSIntersectionRange(last.localRange, issue.localRange).length > 0 {
                // Keep whichever has higher priority.
                if OverlayIssue.priority(of: issue.category) < OverlayIssue.priority(of: last.category) {
                    accepted.removeLast()
                    accepted.append(issue)
                }
                continue
            }
            accepted.append(issue)
        }
        return accepted
    }

    private func operationForAuditCategory(_ raw: String) -> RewriteOperation? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "fix", "fixgrammar", "grammar", "correct", "correction":
            return .fixGrammar
        case "formal", "professional", "makeprofessional", "polish":
            return .makeProfessional
        case "humanize", "human", "natural":
            return .humanize
        case "shorten", "short", "tighten", "concise":
            return .shorten
        default:
            return nil
        }
    }

    private func decodeOverlaySuggestions(_ raw: String, original: String) -> [OverlaySuggestion] {
        guard let json = extractJSONObject(from: raw),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(OverlaySuggestionPayload.self, from: data) else {
            return []
        }

        let ordered: [(RewriteOperation, String?)] = [
            (.fixGrammar, payload.fix),
            (.makeProfessional, payload.formal),
            (.shorten, payload.shorten),
            (.humanize, payload.humanize)
        ]
        var seen = Set<String>()
        var suggestions: [OverlaySuggestion] = []
        let originalKey = normalizedForSuggestionDedupe(original)

        for (operation, value) in ordered {
            let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !cleaned.isEmpty else { continue }
            let key = normalizedForSuggestionDedupe(cleaned)
            guard key != originalKey,
                  !seen.contains(key),
                  preservesProtectedTokens(original: original, candidate: cleaned) else { continue }
            seen.insert(key)
            suggestions.append(OverlaySuggestion(operation: operation, text: cleaned))
        }
        return suggestions
    }

    private func extractJSONObject(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return trimmed
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        return String(trimmed[start...end])
    }

    private func normalizedForSuggestionDedupe(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    private func preservesProtectedTokens(original: String, candidate: String) -> Bool {
        // Case-insensitive comparison so e.g. "Eur" vs "eur" counts as
        // preserved. Order is intentionally ignored via sorting so a
        // model that reorders currency + quantity ("USD 135" ⇄ "135
        // USD") still passes, while a model that drops a protected
        // token entirely does not.
        let left = protectedTokens(in: original)
            .map { $0.lowercased() }
            .sorted()
        let right = protectedTokens(in: candidate)
            .map { $0.lowercased() }
            .sorted()
        return left == right
    }

    private func protectedTokens(in text: String) -> [String] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        // Patterns (all case-insensitive via `(?i)`):
        //   1. http(s)://… / www.… URLs
        //   2. email addresses
        //   3. @mentions / #hashtags
        //   4. phone-like number runs
        //   5. bare numeric tokens (135, 3.14, 12:30, 2024-01-05, …)
        //   6. bare domain names ending in a known TLD
        //   7. ISO-4217 currency codes (EUR, USD, RUB, …) — catches "Eur",
        //      "usd" etc. because of the (?i) flag, so models can't
        //      "correct" them into unrelated English words.
        //   8. currency/unit symbols: €$£¥₽₴₺₹₸₩
        //   9. common unit abbreviations anchored on either side by a
        //      digit or word boundary (kg, km, mph, °C, …)
        let pattern = #"(?i)(?:https?://|www\.)\S+"#
            + #"|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
            + #"|[@#][\p{L}\p{N}_]+(?:[._-][\p{L}\p{N}_]+)*"#
            + #"|\+?\d[\d\s().-]{2,}\d"#
            + #"|\b\d+(?:[.,:/-]\d+)*\b"#
            + #"|\b[\w.-]+\.(?:com|net|org|io|dev|app|ai|co|ru|ua|by|de|fr|es|it|pl|nl|uk)\b\S*"#
            + #"|\b(?:EUR|USD|GBP|JPY|CHF|CAD|AUD|CNY|RMB|RUB|UAH|BYN|KZT|NZD|SEK|NOK|DKK|PLN|CZK|HUF|RON|TRY|BRL|MXN|INR|KRW|SGD|HKD|THB|ZAR|ILS|NIS|VND|IDR|PHP|MYR|EGP|AED|SAR)\b"#
            + #"|[€$£¥₽₴₺₹₸₩]"#
            + #"|\b\d+\s*(?:kg|g|lb|lbs|km|cm|mm|ft|in|mph|kph|oz|ml|l)\b"#
            + #"|°[CF]\b"#
        var tokens: [String] = []
        if let regex = try? NSRegularExpression(pattern: pattern) {
            tokens.append(contentsOf: regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range) })
        }
        tokens.append(contentsOf: properNameTokens(in: text))
        tokens.append(contentsOf: emojiTokens(in: text))
        return tokens
    }

    private func properNameTokens(in text: String) -> [String] {
        lexicalTokens(in: text).filter { token in
            guard token.count >= 3 else { return false }
            guard let first = token.first, first.isUppercase else { return false }
            guard token.dropFirst().contains(where: { $0.isLowercase }) else { return false }
            let lower = token.lowercased()
            return !Self.commonTitleCaseWords.contains(lower)
        }
    }

    private func lexicalTokens(in text: String) -> [String] {
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"\b[\p{L}][\p{L}'’-]*\b"#) else {
            return []
        }
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    private func emojiTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let cluster = text[index..<next]
            if cluster.unicodeScalars.contains(where: isEmojiScalar) {
                tokens.append(String(cluster))
            }
            index = next
        }
        return tokens
    }

    private func isEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isEmojiPresentation { return true }
        if scalar.value == 0xFE0F || scalar.value == 0x200D { return true }
        guard scalar.properties.isEmoji else { return false }
        return !(0x30...0x39).contains(scalar.value)
    }

    private static let commonTitleCaseWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "from", "hi", "hello", "hey", "i", "if", "in", "interview",
        "is", "it", "its", "of", "on", "or", "please", "so", "the", "then", "to", "with", "you", "your"
    ]

    private func availableOpenAIModels(apiKey: String) async throws -> [AIModelOption] {
        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            throw modelCatalogError(provider: "OpenAI", detail: "Invalid models URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let data = try await modelCatalogData(for: request, provider: "OpenAI")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = json?["data"] as? [[String: Any]] ?? []
        let models: [(option: AIModelOption, created: Int)] = entries.compactMap { entry in
            guard let id = entry["id"] as? String, isOpenAITextModel(id) else { return nil }
            return (
                AIModelOption(id: id, displayName: id),
                entry["created"] as? Int ?? 0
            )
        }
        return uniqueModelOptions(
            models.sorted {
                $0.created == $1.created
                    ? $0.option.id.localizedStandardCompare($1.option.id) == .orderedAscending
                    : $0.created > $1.created
            }.map(\.option)
        )
    }

    private func availableGeminiModels(apiKey: String) async throws -> [AIModelOption] {
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")
        components?.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
        guard let url = components?.url else {
            throw modelCatalogError(provider: "Gemini", detail: "Invalid models URL")
        }

        let request = Self.geminiRequest(url: url, apiKey: apiKey, timeoutInterval: 20)
        let data = try await modelCatalogData(for: request, provider: "Gemini")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = json?["models"] as? [[String: Any]] ?? []
        let models = entries.compactMap { entry -> AIModelOption? in
            let methods = entry["supportedGenerationMethods"] as? [String] ?? []
            guard methods.contains("generateContent") else { return nil }
            let resourceName = entry["name"] as? String ?? ""
            let id = (entry["baseModelId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? resourceName.replacingOccurrences(of: "models/", with: "")
            guard isGeminiTextModel(id) else { return nil }
            let displayName = (entry["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return AIModelOption(id: id, displayName: displayName?.isEmpty == false ? displayName! : id)
        }
        return uniqueModelOptions(models).sorted {
            $0.id.localizedStandardCompare($1.id) == .orderedDescending
        }
    }

    private func availableClaudeModels(apiKey: String) async throws -> [AIModelOption] {
        guard let url = URL(string: "https://api.anthropic.com/v1/models?limit=1000") else {
            throw modelCatalogError(provider: "Claude", detail: "Invalid models URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let data = try await modelCatalogData(for: request, provider: "Claude")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = json?["data"] as? [[String: Any]] ?? []
        return uniqueModelOptions(entries.compactMap { entry -> AIModelOption? in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let displayName = entry["display_name"] as? String
            return AIModelOption(id: id, displayName: displayName?.isEmpty == false ? displayName! : id)
        })
    }

    private func modelCatalogData(for request: URLRequest, provider: String) async throws -> Data {
        let (data, response) = try await Self.secureData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw modelCatalogError(provider: provider, detail: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = providerErrorDetail(data) ?? "HTTP \(http.statusCode)"
            throw modelCatalogError(provider: provider, detail: detail)
        }
        return data
    }

    private func providerErrorDetail(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(280), encoding: .utf8)
        }
        if let error = json["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["status"] as? String)
        }
        return json["message"] as? String
    }

    private func modelCatalogError(provider: String, detail: String) -> NSError {
        NSError(
            domain: "Textora",
            code: 20,
            userInfo: [NSLocalizedDescriptionKey: "Could not load \(provider) models: \(detail)"]
        )
    }

    private func uniqueModelOptions(_ options: [AIModelOption]) -> [AIModelOption] {
        var seen = Set<String>()
        return options.filter { seen.insert($0.id).inserted }
    }

    private func isOpenAITextModel(_ id: String) -> Bool {
        let value = id.lowercased()
        let isReasoningModel = value.first == "o" && value.dropFirst().first?.isNumber == true
        let isSupportedFamily = value.hasPrefix("gpt-")
            || isReasoningModel
            || (value.hasPrefix("ft:") && value.contains("gpt"))
        guard isSupportedFamily else { return false }
        let excludedFragments = [
            "audio", "codex", "computer-use", "deep-research", "image", "moderation",
            "realtime", "search", "transcribe", "tts"
        ]
        return !excludedFragments.contains(where: value.contains)
    }

    private func isGeminiTextModel(_ id: String) -> Bool {
        let value = id.lowercased()
        guard value.hasPrefix("gemini-") || value.hasPrefix("gemma-") else { return false }
        let excludedFragments = [
            "audio", "computer-use", "deep-research", "image", "live", "robotics", "tts"
        ]
        return !excludedFragments.contains(where: value.contains)
    }

    private func rewriteOpenAI(
        model: String,
        apiKey: String,
        text: String,
        operation: RewriteOperation,
        systemPromptOverride: String?
    ) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw NSError(domain: "Textora", code: 7, userInfo: [NSLocalizedDescriptionKey: "OpenAI API key is empty"])
        }
        let modelId = trimmedOpenAIModel(model)

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw NSError(domain: "Textora", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid OpenAI URL"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let body = chatCompletionsBody(
            model: modelId,
            systemPrompt: systemPromptOverride ?? operation.prompt,
            userText: text
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.secureData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Textora", code: 2, userInfo: [NSLocalizedDescriptionKey: "OpenAI request failed: no HTTP response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = openAIErrorUserMessage(data: data, statusCode: http.statusCode)
            throw NSError(domain: "Textora", code: 2, userInfo: [NSLocalizedDescriptionKey: detail])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let content = (message?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let content, !content.isEmpty else {
            throw NSError(domain: "Textora", code: 3, userInfo: [NSLocalizedDescriptionKey: "OpenAI returned empty text"])
        }
        return content
    }

    private func trimmedOpenAIModel(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? Defaults.openAIModel : t
    }

    private func openAIErrorUserMessage(data: Data, statusCode: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String,
           !msg.isEmpty {
            return "OpenAI request failed (HTTP \(statusCode)): \(msg)"
        }
        let snippet = String(data: data.prefix(280), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !snippet.isEmpty {
            return "OpenAI request failed (HTTP \(statusCode)): \(snippet)"
        }
        return "OpenAI request failed (HTTP \(statusCode))"
    }

    private func rewriteGemini(
        model: String,
        apiKey: String,
        text: String,
        operation: RewriteOperation,
        systemPromptOverride: String?
    ) async throws -> String {
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw NSError(domain: "Textora", code: 4, userInfo: [NSLocalizedDescriptionKey: "Gemini API key is empty"])
        }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent") else {
            throw NSError(domain: "Textora", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini URL"])
        }
        var request = Self.geminiRequest(url: url, apiKey: key)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let prompt = "\(systemPromptOverride ?? operation.prompt)\n\n\(text)"
        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.secureData(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "Textora", code: 5, userInfo: [NSLocalizedDescriptionKey: "Gemini request failed"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let candidates = json?["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        let result = (parts?.first?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let result, !result.isEmpty else {
            throw NSError(domain: "Textora", code: 6, userInfo: [NSLocalizedDescriptionKey: "Gemini returned empty text"])
        }
        return result
    }

    private func rewriteClaude(
        model: String,
        apiKey: String,
        text: String,
        operation: RewriteOperation,
        systemPromptOverride: String?
    ) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw NSError(domain: "Textora", code: 14, userInfo: [NSLocalizedDescriptionKey: "Claude API key is empty"])
        }
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw NSError(domain: "Textora", code: 15, userInfo: [NSLocalizedDescriptionKey: "Invalid Claude URL"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Defaults.claudeModel : model,
            "max_tokens": 1024,
            "system": systemPromptOverride ?? operation.prompt,
            "messages": [
                ["role": "user", "content": text]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.secureData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Textora", code: 16, userInfo: [NSLocalizedDescriptionKey: "Claude request failed: no HTTP response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(280), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = snippet.isEmpty
                ? "Claude request failed (HTTP \(http.statusCode))"
                : "Claude request failed (HTTP \(http.statusCode)): \(snippet)"
            throw NSError(domain: "Textora", code: 17, userInfo: [NSLocalizedDescriptionKey: message])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = json?["content"] as? [[String: Any]]
        let textPart = content?.first(where: { ($0["type"] as? String) == "text" })
        let result = (textPart?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let result, !result.isEmpty else {
            throw NSError(domain: "Textora", code: 18, userInfo: [NSLocalizedDescriptionKey: "Claude returned empty text"])
        }
        return result
    }

    private func rewriteOpenAICompatible(
        model: String,
        token: String,
        text: String,
        operation: RewriteOperation,
        systemPromptOverride: String?
    ) async throws -> String {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw NSError(domain: "Textora", code: 9, userInfo: [NSLocalizedDescriptionKey: "API token is empty"])
        }
        let base = UserDefaults.standard
            .string(forKey: Self.openAICompatibleBaseURLUserDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !base.isEmpty else {
            throw NSError(domain: "Textora", code: 10, userInfo: [NSLocalizedDescriptionKey: "Set API base URL in Settings (Other AI)"])
        }
        guard let url = Self.validatedOpenAICompatibleURL(from: base) else {
            throw NSError(domain: "Textora", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid API base URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")

        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Defaults.customModel
            : model
        let body = chatCompletionsBody(
            model: resolvedModel,
            systemPrompt: systemPromptOverride ?? operation.prompt,
            userText: text
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.secureData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Textora", code: 11, userInfo: [NSLocalizedDescriptionKey: "OpenAI-compatible request failed: no HTTP response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(280), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = snippet.isEmpty
                ? "OpenAI-compatible request failed (HTTP \(http.statusCode))"
                : "OpenAI-compatible request failed (HTTP \(http.statusCode)): \(snippet)"
            throw NSError(domain: "Textora", code: 12, userInfo: [NSLocalizedDescriptionKey: message])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let content = (message?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let content, !content.isEmpty else {
            throw NSError(domain: "Textora", code: 13, userInfo: [NSLocalizedDescriptionKey: "OpenAI-compatible API returned empty text"])
        }
        return content
    }

    static func validatedOpenAICompatibleURL(from rawBaseURL: String) -> URL? {
        let trimmed = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else { return nil }
        let path = url.path.lowercased()
        if path.hasSuffix("/chat/completions") {
            return url
        }
        if path.hasSuffix("/v1") {
            return url.appendingPathComponent("chat").appendingPathComponent("completions")
        }
        if path.isEmpty || path == "/" {
            return url.appendingPathComponent("v1").appendingPathComponent("chat").appendingPathComponent("completions")
        }
        return url.appendingPathComponent("v1").appendingPathComponent("chat").appendingPathComponent("completions")
    }

    static func geminiRequest(url: URL, apiKey: String, timeoutInterval: TimeInterval = 60) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.setValue(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    /// Keep the shared Chat Completions payload model-neutral. Sampling and
    /// reasoning parameters are intentionally omitted because their accepted
    /// values vary by model and provider; each API applies its supported defaults.
    private func chatCompletionsBody(
        model: String,
        systemPrompt: String,
        userText: String
    ) -> [String: Any] {
        [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ]
        ]
    }
}
