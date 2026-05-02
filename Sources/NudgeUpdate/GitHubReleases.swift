import Foundation

/// Tiny GitHub Releases client. Just enough to fetch the latest release
/// tag and the download URL for a named asset (`Nudge.app.zip`). No
/// token: works for public repos within the unauthenticated rate limit.
enum GitHubReleases {
    enum Failure: Error, CustomStringConvertible {
        case network(Error)
        case http(Int, String)
        case malformed(String)

        var description: String {
            switch self {
            case .network(let e): return "network: \(e.localizedDescription)"
            case .http(let code, let body):
                let snippet = body.prefix(200)
                return "http \(code): \(snippet)"
            case .malformed(let why): return "malformed response: \(why)"
            }
        }
    }

    struct Release {
        let tag: String
        let assetURL: URL?  // download URL for `Nudge.app.zip`, if attached
    }

    /// `repo` is `owner/name`, e.g. `ZachDeLong/nudge`.
    /// Synchronous on purpose — this is a CLI, not a daemon.
    static func latest(repo: String, assetName: String = "Nudge.app.zip") throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("nudge-update", forHTTPHeaderField: "User-Agent")

        let result = synchronousFetch(req)
        switch result {
        case .failure(let err): throw Failure.network(err)
        case .success(let (data, response)):
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else {
                throw Failure.http(status, String(data: data, encoding: .utf8) ?? "")
            }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.malformed("not a JSON object")
            }
            guard let tag = root["tag_name"] as? String else {
                throw Failure.malformed("missing tag_name")
            }
            let assets = root["assets"] as? [[String: Any]] ?? []
            let asset = assets.first { ($0["name"] as? String) == assetName }
            let assetURL = (asset?["browser_download_url"] as? String).flatMap(URL.init(string:))
            return Release(tag: tag, assetURL: assetURL)
        }
    }

    private static func synchronousFetch(_ req: URLRequest) -> Result<(Data, URLResponse), Error> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(Data, URLResponse), Error> = .failure(NSError(domain: "init", code: 0))
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                result = .failure(err)
            } else if let data = data, let resp = resp {
                result = .success((data, resp))
            } else {
                result = .failure(Failure.malformed("empty response"))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return result
    }
}
