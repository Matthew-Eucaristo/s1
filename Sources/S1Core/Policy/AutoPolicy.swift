import Foundation

/// `--policy auto` (the default): a REAL decision model when its endpoint
/// answers, the deterministic grammar policy when it doesn't.
///
/// The endpoint probe happens ONCE per command — a single 3-second budget
/// at startup, never per step — so an unreachable server costs one small
/// delay, not a stall on every decision.
public enum AutoPolicy {

    /// One-shot reachability probe for an OpenAI-compatible endpoint:
    /// `/models` (OpenAI/vLLM/MLX) then `/api/tags` (Ollama).
    public static func endpointAlive(_ ep: Endpoint) async -> Bool {
        for path in ["/models", "/api/tags"] {
            guard let url = URL(string: ep.baseURL + path) else { break }
            var req = URLRequest(url: url)
            req.timeoutInterval = 3
            if let key = ep.apiKey {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 { return true }
        }
        return false
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
