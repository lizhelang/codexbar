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
    func makeCSV(
        from accounts: [TokenAccount],
        metadataByAccountID: [String: OAuthAccountInteropMetadata] = [:],
        proxiesJSON: String? = nil,
        now: Date = Date()
    ) throws -> String {
        let proxyObjects = self.decodeJSONArray(proxiesJSON)?.compactMap { $0 as? [String: Any] } ?? []
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
            proxiesJSON: proxiesJSON,
            availableProxyKeys: []
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
        let parsed: PortableCoreOAuthAccountImportParseResult
        do {
            parsed = try RustPortableCoreAdapter.shared.parseOAuthAccountImport(
                PortableCoreOAuthAccountImportParseRequest(text: text),
                buildIfNeeded: true
            )
        } catch let RustPortableCoreAdapterError.bridgeError(ffiError) {
            switch ffiError.message {
            case "emptyFile":
                throw OpenAIAccountCSVError.emptyFile
            case "invalidDataFile":
                throw OpenAIAccountCSVError.invalidDataFile
            case "unsupportedDataType":
                throw OpenAIAccountCSVError.unsupportedDataType
            case "noImportableAccounts":
                throw OpenAIAccountCSVError.noImportableAccounts
            case "missingRequiredColumns":
                throw OpenAIAccountCSVError.missingRequiredColumns
            case "unsupportedFormatVersion":
                throw OpenAIAccountCSVError.unsupportedFormatVersion
            case "duplicateAccountID":
                throw OpenAIAccountCSVError.duplicateAccountID
            case "multipleActiveAccounts":
                throw OpenAIAccountCSVError.multipleActiveAccounts
            default:
                if let row = Self.parseIndexedInteropError(ffiError.message, prefix: "invalidCSV:") {
                    throw OpenAIAccountCSVError.invalidCSV(row: row)
                }
                if let row = Self.parseIndexedInteropError(ffiError.message, prefix: "invalidActiveValue:") {
                    throw OpenAIAccountCSVError.invalidActiveValue(row: row)
                }
                if let row = Self.parseIndexedInteropError(ffiError.message, prefix: "accountIDMismatch:") {
                    throw OpenAIAccountCSVError.accountIDMismatch(row: row)
                }
                if let row = Self.parseIndexedInteropError(ffiError.message, prefix: "emailMismatch:") {
                    throw OpenAIAccountCSVError.emailMismatch(row: row)
                }
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
            activeAccountID: parsed.activeAccountID,
            rowCount: parsed.rowCount,
            interopContext: OAuthAccountImportInterchangeContext(
                accountMetadataByID: metadataByAccountID,
                proxiesJSON: parsed.proxiesJSON
            )
        )
    }

    private static func parseIndexedInteropError(_ message: String, prefix: String) -> Int? {
        guard message.hasPrefix(prefix) else { return nil }
        return Int(message.dropFirst(prefix.count))
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
