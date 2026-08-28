import Foundation

struct OpenAIProfileSnapshot: Equatable {
    let username: String?
    let displayName: String?

    init(username: String?, displayName: String?) {
        self.username = TokenAccount.normalizedProfileString(username)
        self.displayName = TokenAccount.normalizedProfileString(displayName)
    }
}

struct OpenAIProfileService {
    nonisolated static let shared = OpenAIProfileService()
    nonisolated static let defaultRefreshInterval: TimeInterval = 60 * 60

    private struct ProfileResponse: Decodable {
        let username: String?
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case username
            case displayName = "display_name"
        }
    }

    private let baseURL: URL
    private let urlSession: URLSession

    init(
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api/calpico/chatgpt/profile")!,
        urlSession: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession ?? URLSession(configuration: .ephemeral)
    }

    func fetchProfile(account: TokenAccount) async -> OpenAIProfileSnapshot? {
        guard let userID = AccountBuilder.chatGPTUserID(fromAccessToken: account.accessToken),
              let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowedCharacters),
              encodedUserID.isEmpty == false,
              let url = URL(string: "\(self.profileBaseURLString)/\(encodedUserID)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN", forHTTPHeaderField: "oai-language")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        if account.remoteAccountId.isEmpty == false {
            request.setValue(account.remoteAccountId, forHTTPHeaderField: "chatgpt-account-id")
        }

        do {
            let (data, response) = try await self.urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            let decoded = try JSONDecoder().decode(ProfileResponse.self, from: data)
            let profile = OpenAIProfileSnapshot(
                username: decoded.username,
                displayName: decoded.displayName
            )
            return profile
        } catch {
            return nil
        }
    }

    private var profileBaseURLString: String {
        let value = self.baseURL.absoluteString
        guard value.hasSuffix("/") else { return value }
        return String(value.dropLast())
    }

    private static let pathSegmentAllowedCharacters: CharacterSet = {
        var characters = CharacterSet.urlPathAllowed
        characters.remove(charactersIn: "/")
        return characters
    }()
}
