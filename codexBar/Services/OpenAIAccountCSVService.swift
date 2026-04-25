import Foundation

struct ParsedOpenAIAccountCSV {
    let accounts: [TokenAccount]
    let activeAccountID: String?
    let rowCount: Int
    let interopContext: OAuthAccountImportInterchangeContext
}

enum OpenAIAccountCSVError: LocalizedError, Equatable {
    case emptyFile
    case invalidDataFile
    case unsupportedDataType
    case noImportableAccounts
    case missingRequiredValue(index: Int)
    case invalidAccount(index: Int)
    case missingRequiredColumns
    case unsupportedFormatVersion
    case invalidCSV(row: Int)
    case accountIDMismatch(row: Int)
    case emailMismatch(row: Int)
    case duplicateAccountID
    case multipleActiveAccounts
    case invalidActiveValue(row: Int)

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return L.openAIAccountDataEmptyFile
        case .invalidDataFile:
            return L.openAIAccountDataInvalidFile
        case .unsupportedDataType:
            return L.openAIAccountDataUnsupportedType
        case .noImportableAccounts:
            return L.openAIAccountDataNoImportableAccounts
        case let .missingRequiredValue(index):
            return L.openAIAccountDataMissingRequiredValue(index)
        case let .invalidAccount(index):
            return L.openAIAccountDataInvalidAccount(index)
        case .missingRequiredColumns:
            return L.openAIAccountDataMissingColumns
        case .unsupportedFormatVersion:
            return L.openAIAccountDataUnsupportedVersion
        case let .invalidCSV(row):
            return L.openAIAccountDataInvalidRow(row)
        case let .accountIDMismatch(row):
            return L.openAIAccountDataAccountIDMismatch(row)
        case let .emailMismatch(row):
            return L.openAIAccountDataEmailMismatch(row)
        case .duplicateAccountID:
            return L.openAIAccountDataDuplicateAccounts
        case .multipleActiveAccounts:
            return L.openAIAccountDataMultipleActiveAccounts
        case let .invalidActiveValue(row):
            return L.openAIAccountDataInvalidActiveValue(row)
        }
    }
}

struct OpenAIAccountCSVService {
    static let formatVersion = "v1"
    static let headerOrder = [
        "format_version",
        "email",
        "account_id",
        "access_token",
        "refresh_token",
        "id_token",
        "is_active",
    ]

    func makeCSV(
        from accounts: [TokenAccount],
        metadataByAccountID: [String: OAuthAccountInteropMetadata] = [:],
        proxiesJSON: String? = nil,
        now: Date = Date()
    ) throws -> String {
        let proxyObjects = self.decodeJSONArray(proxiesJSON)?.compactMap { $0 as? [String: Any] } ?? []
        let availableProxyKeys = Set(proxyObjects.compactMap { self.trimmedString($0["proxy_key"]) })
        let exportRequest = PortableCoreOAuthInteropExportRequest(
            accounts: accounts.map(PortableCoreOAuthInteropExportAccountInput.legacy(from:)),
            metadataEntries: metadataByAccountID.map { accountID, metadata in
                PortableCoreOAuthInteropMetadataEntry(
                    accountId: accountID,
                    proxyKey: metadata.proxyKey,
                    notes: metadata.notes,
                    concurrency: metadata.concurrency,
                    priority: metadata.priority,
                    rateMultiplier: metadata.rateMultiplier,
                    autoPauseOnExpired: metadata.autoPauseOnExpired,
                    credentialsJSON: metadata.credentialsJSON,
                    extraJSON: metadata.extraJSON
                )
            },
            availableProxyKeys: Array(availableProxyKeys).sorted()
        )
        let accountsPayload = try? RustPortableCoreAdapter.shared
            .renderOAuthInteropExportAccounts(exportRequest, buildIfNeeded: true)
            .accountsPayload
        guard
            let accountsPayload,
            let accountsData = accountsPayload.data(using: .utf8),
            let accountObjects = try? JSONSerialization.jsonObject(with: accountsData) as? [[String: Any]]
        else {
            throw OpenAIAccountCSVError.invalidDataFile
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let payload: [String: Any] = [
            "exported_at": formatter.string(from: now),
            "proxies": proxyObjects,
            "accounts": accountObjects,
        ]

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            throw OpenAIAccountCSVError.invalidDataFile
        }

        return text + "\n"
    }

    func parseCSV(_ text: String) throws -> ParsedOpenAIAccountCSV {
        let normalized = self.normalize(text)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw OpenAIAccountCSVError.emptyFile
        }

        if let first = trimmed.first, first == "{" {
            return try self.parseInteropJSON(trimmed)
        }

        return try self.parseLegacyCSV(normalized)
    }

    private func parseInteropJSON(_ text: String) throws -> ParsedOpenAIAccountCSV {
        let parsed: PortableCoreOAuthInteropBundleParseResult
        do {
            parsed = try RustPortableCoreAdapter.shared.parseOAuthInteropBundle(
                PortableCoreOAuthInteropBundleParseRequest(text: text),
                buildIfNeeded: true
            )
        } catch let RustPortableCoreAdapterError.bridgeError(ffiError) {
            switch ffiError.message {
            case "invalidDataFile":
                throw OpenAIAccountCSVError.invalidDataFile
            case "unsupportedDataType":
                throw OpenAIAccountCSVError.unsupportedDataType
            case "noImportableAccounts":
                throw OpenAIAccountCSVError.noImportableAccounts
            default:
                if let index = Self.parseIndexedInteropError(
                    ffiError.message,
                    prefix: "missingRequiredValue:"
                ) {
                    throw OpenAIAccountCSVError.missingRequiredValue(index: index)
                }
                if let index = Self.parseIndexedInteropError(
                    ffiError.message,
                    prefix: "invalidAccount:"
                ) {
                    throw OpenAIAccountCSVError.invalidAccount(index: index)
                }
                throw OpenAIAccountCSVError.invalidDataFile
            }
        } catch {
            throw OpenAIAccountCSVError.invalidDataFile
        }

        let metadataByAccountID = Dictionary(
            uniqueKeysWithValues: parsed.metadataEntries.map { entry in
                (
                    entry.accountId,
                    OAuthAccountInteropMetadata(
                        proxyKey: entry.proxyKey,
                        notes: entry.notes,
                        concurrency: entry.concurrency,
                        priority: entry.priority,
                        rateMultiplier: entry.rateMultiplier,
                        autoPauseOnExpired: entry.autoPauseOnExpired,
                        credentialsJSON: entry.credentialsJSON,
                        extraJSON: entry.extraJSON
                    )
                )
            }
        )

        return ParsedOpenAIAccountCSV(
            accounts: parsed.accounts.map { $0.tokenAccount() },
            activeAccountID: parsed.activeAccountId,
            rowCount: parsed.rowCount,
            interopContext: OAuthAccountImportInterchangeContext(
                accountMetadataByID: metadataByAccountID,
                proxiesJSON: parsed.proxiesJSON
            )
        )
    }

    private func parseLegacyCSV(_ text: String) throws -> ParsedOpenAIAccountCSV {
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let headerIndex = rawLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else {
            throw OpenAIAccountCSVError.emptyFile
        }

        let headerRowNumber = headerIndex + 1
        let headers = try self.parseCSVLine(rawLines[headerIndex], rowNumber: headerRowNumber).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let headerSet = Set(headers)
        guard headerSet.count == headers.count,
              headerSet.isSuperset(of: Set(Self.headerOrder)) else {
            throw OpenAIAccountCSVError.missingRequiredColumns
        }

        let headerIndexMap = Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($1, $0) })
        var accounts: [TokenAccount] = []
        var seenAccountIDs: Set<String> = []
        var activeAccountID: String?

        for lineIndex in rawLines.index(after: headerIndex)..<rawLines.endIndex {
            let line = rawLines[lineIndex]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            let rowNumber = lineIndex + 1
            let columns = try self.parseCSVLine(line, rowNumber: rowNumber)
            guard columns.count == headers.count else {
                throw OpenAIAccountCSVError.invalidCSV(row: rowNumber)
            }

            func value(for key: String) -> String {
                guard let index = headerIndexMap[key] else {
                    preconditionFailure("Validated CSV header missing column: \(key)")
                }
                let field = columns[index]
                return field.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard value(for: "format_version").lowercased() == Self.formatVersion else {
                throw OpenAIAccountCSVError.unsupportedFormatVersion
            }

            let accessToken = value(for: "access_token")
            let refreshToken = value(for: "refresh_token")
            let idToken = value(for: "id_token")
            guard accessToken.isEmpty == false,
                  refreshToken.isEmpty == false,
                  idToken.isEmpty == false else {
                throw OpenAIAccountCSVError.missingRequiredValue(index: rowNumber)
            }

            let builtAccount = try RustPortableCoreAdapter.shared.buildOAuthAccountFromTokens(
                PortableCoreOAuthAccountBuildRequest(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    idToken: idToken,
                    oauthClientID: nil,
                    tokenLastRefreshAt: nil
                ),
                buildIfNeeded: false
            ).tokenAccount()
            guard builtAccount.accountId.isEmpty == false else {
                throw OpenAIAccountCSVError.invalidAccount(index: rowNumber)
            }

            let declaredAccountID = value(for: "account_id")
            if declaredAccountID.isEmpty == false &&
                declaredAccountID != builtAccount.accountId &&
                declaredAccountID != builtAccount.remoteAccountId {
                throw OpenAIAccountCSVError.accountIDMismatch(row: rowNumber)
            }

            let declaredEmail = value(for: "email")
            if declaredEmail.isEmpty == false && declaredEmail != builtAccount.email {
                throw OpenAIAccountCSVError.emailMismatch(row: rowNumber)
            }

            if seenAccountIDs.insert(builtAccount.accountId).inserted == false {
                throw OpenAIAccountCSVError.duplicateAccountID
            }

            let isActive = try self.parseActiveFlag(value(for: "is_active"), rowNumber: rowNumber)
            if isActive {
                if activeAccountID != nil {
                    throw OpenAIAccountCSVError.multipleActiveAccounts
                }
                activeAccountID = builtAccount.accountId
            }

            var account = builtAccount
            account.isActive = false
            accounts.append(account)
        }

        guard accounts.isEmpty == false else {
            throw OpenAIAccountCSVError.emptyFile
        }

        return ParsedOpenAIAccountCSV(
            accounts: accounts,
            activeAccountID: activeAccountID,
            rowCount: accounts.count,
            interopContext: .empty
        )
    }

    private func normalize(_ text: String) -> String {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalized.first == "\u{FEFF}" {
            normalized.removeFirst()
        }
        return normalized
    }

    private func parseActiveFlag(_ value: String, rowNumber: Int) throws -> Bool {
        switch value.lowercased() {
        case "true":
            return true
        case "false":
            return false
        default:
            throw OpenAIAccountCSVError.invalidActiveValue(row: rowNumber)
        }
    }

    private func parseCSVLine(_ line: String, rowNumber: Int) throws -> [String] {
        let characters = Array(line)
        var fields: [String] = []
        var current = ""
        var index = 0
        var isQuoted = false

        while index < characters.count {
            let character = characters[index]
            if isQuoted {
                if character == "\"" {
                    let nextIndex = index + 1
                    if nextIndex < characters.count && characters[nextIndex] == "\"" {
                        current.append("\"")
                        index += 1
                    } else {
                        isQuoted = false
                    }
                } else {
                    current.append(character)
                }
            } else {
                switch character {
                case ",":
                    fields.append(current)
                    current = ""
                case "\"":
                    guard current.isEmpty else {
                        throw OpenAIAccountCSVError.invalidCSV(row: rowNumber)
                    }
                    isQuoted = true
                default:
                    current.append(character)
                }
            }
            index += 1
        }

        guard isQuoted == false else {
            throw OpenAIAccountCSVError.invalidCSV(row: rowNumber)
        }
        fields.append(current)
        return fields
    }

    private static func parseIndexedInteropError(_ message: String, prefix: String) -> Int? {
        guard message.hasPrefix(prefix) else { return nil }
        return Int(message.dropFirst(prefix.count))
    }

    private func trimmedString(_ value: Any?) -> String? {
        guard let value else {
            return nil
        }
        if value is NSNull {
            return nil
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let double as Double:
            return double
        case let float as Float:
            return Double(float)
        case let int as Int:
            return Double(int)
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "on":
                return true
            case "false", "0", "no", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private func decodeJSONArray(_ json: String?) -> [Any]? {
        guard let json,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let array = object as? [Any] else {
            return nil
        }
        return array
    }
}
