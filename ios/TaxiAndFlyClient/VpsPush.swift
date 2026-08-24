import Foundation

enum VpsPush {
    static func sendChat(token: String, title: String, body: String) {
        guard let url = URL(string: "\(AppConfig.apiUrl)/api/push/chat") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(AppConfig.apiKey, forHTTPHeaderField: "X-API-Key")
        req.timeoutInterval = 25
        let payload: [String: String] = ["token": token, "title": title, "body": body]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req).resume()
    }
}
