import Foundation

/// `--policy auto` (the default): a REAL decision model when its endpoint
/// answers, the deterministic grammar policy when it doesn't.
///
/// The endpoint probe happens ONCE per command — a single 3-second budget
/// at startup, never per step — so an unreachable server costs one small
/// delay, not a stall on every decision.
public enum AutoPolicy {

    /// One-shot usability probe for an OpenAI-compatible endpoint:
    /// `/models` (OpenAI/vLLM/MLX/Ollama-shim) then `/api/tags` (Ollama).
    /// A 200 is not enough — the server can be perfectly alive while the
    /// configured model was never pulled, which would burn every step on
    /// "model not found". So a parseable list must actually contain it.
    public static func endpointAlive(_ ep: Endpoint) async -> Bool {
        for path in ["/models", "/api/tags"] {
            guard let url = URL(string: ep.baseURL + path) else { break }
            var req = URLRequest(url: url)
            req.timeoutInterval = 3
            if let key = ep.apiKey {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
            return modelListed(ep.model, in: data)
        }
        return false
    }

    /// Does a model-list response contain the model we want?
    /// OpenAI shape: `{"data":[{"id":"…"}]}`; Ollama shape:
    /// `{"models":[{"name":"…"}]}`. An unparseable or empty list can't
    /// prove the model missing — count it usable rather than guessing.
    /// Tags match loosely: "gemma3" should find "gemma3:4b".
    static func modelListed(_ want: String, in data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return true }
        var names: [String] = []
        if let d = obj["data"] as? [[String: Any]] {
            names += d.compactMap { $0["id"] as? String }
        }
        if let m = obj["models"] as? [[String: Any]] {
            names += m.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
        }
        if names.isEmpty { return true }
        let w = want.lowercased()
        return names.contains { n in
            let s = n.lowercased()
            return s == w || s.hasPrefix(w + ":") || w.hasPrefix(s + ":")
        }
    }

    /// Resolve `auto` to a concrete policy. Returns the policy plus the
    /// resolved name ("vlm" / "ax") for logs and the steps.jsonl evidence.
    public static func resolve(vlmBase: String?, vlmModel: String?,
                               useScreenshot: Bool) async -> (policy: any Policy, name: String) {
        let ep = Endpoints.vlm(base: vlmBase, model: vlmModel)
        if await endpointAlive(ep) {
            return (VLMPolicy(endpoint: ep, useScreenshot: useScreenshot), "vlm")
        }
        return (AXPolicy(), "ax")
    }
}
