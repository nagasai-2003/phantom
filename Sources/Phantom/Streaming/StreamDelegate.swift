import WebKit

class StreamDelegate: NSObject, URLSessionDataDelegate {
    // Turns a provider error body into a readable line; rate limits say how long to wait.
    static func describeError(_ status: String, body: Data) -> String {
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let detail = ((json?["error"] as? [String: Any])?["message"] as? String)
            ?? String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if status == "HTTP 429" {
            let wait = detail.range(of: "try again in [0-9.]+m?s", options: .regularExpression).map { String(detail[$0]) }
            return "Rate limit reached on your AI provider. " + (wait.map { "Please \($0), then press retry." } ?? "Wait a few seconds, then press retry.")
        }
        return detail.isEmpty ? status : "\(status): \(detail.prefix(300))"
    }

    let webView: WKWebView
    let parser:  StreamParser
    var buffer = Data()
    var httpError: String? = nil

    init(webView: WKWebView, parser: StreamParser) {
        self.webView = webView; self.parser = parser
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            httpError = "HTTP \(http.statusCode)"
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        if httpError != nil { return }
        let str   = String(data: buffer, encoding: .utf8) ?? ""
        let lines = str.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            guard !line.isEmpty, i < lines.count - 1 else { continue }
            if let token = parser.token(from: line) {
                let escaped = token
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                    .replacingOccurrences(of: "$", with: "\\$")
                DispatchQueue.main.async {
                    self.webView.evaluateJavaScript("appendToken(`\(escaped)`)", completionHandler: nil)
                }
            }
        }
        buffer = lines.last.flatMap { $0.isEmpty ? nil : $0.data(using: .utf8) } ?? Data()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var isError = error != nil
        var msg: String? = nil
        if let e = httpError {
            isError = true
            msg = Self.describeError(e, body: buffer)
        }
        DispatchQueue.main.async {
            if let m = msg {
                self.webView.evaluateJavaScript("appendToken(\(jsonString([m]))[0])", completionHandler: nil)
            }
            self.webView.evaluateJavaScript("endStream(\(isError))", completionHandler: nil)
        }
    }
}
