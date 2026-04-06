import http from "k6/http";
import { check, sleep } from "k6";
import { Counter, Rate, Trend } from "k6/metrics";

// ========================================
// Configuration
// ========================================
const HOST = __ENV.HOST || "maas.example.com";
const PROTOCOL = __ENV.PROTOCOL || "https";
const MODEL_NAME = __ENV.MODEL_NAME || "facebook-opt-125m-simulated";
const MODEL_BASE_PATH = __ENV.MODEL_BASE_PATH || "llm";
const MODEL_PAYLOAD_ID = __ENV.MODEL_PAYLOAD_ID || "facebook/opt-125m";
const AUTH_HEADER = __ENV.AUTH_HEADER || "";
const MAX_TOKENS = Number(__ENV.MAX_TOKENS || 50);
const VUS = Number(__ENV.VUS || 5);
const ITERATIONS = Number(__ENV.ITERATIONS || 50);

// ========================================
// Custom metrics
// ========================================
const inferenceSuccess = new Rate("inference_success");
const inferenceLatency = new Trend("inference_latency", true);
const ttft = new Trend("time_to_first_token", true);
const tokensGenerated = new Counter("tokens_generated");

// ========================================
// Scenario configuration
// ========================================
export const options = {
    scenarios: {
        inference_test: {
            executor: "shared-iterations",
            exec: "inferenceTest",
            vus: VUS,
            iterations: ITERATIONS,
            maxDuration: "30m"
        }
    },
    thresholds: {
        http_req_duration: ["p(95)<5000"],
        http_req_failed: ["rate<0.1"],
        inference_success: ["rate>0.9"],
    },
    insecureSkipTLSVerify: true,
};

// ========================================
// Test function
// ========================================
export function inferenceTest() {
    const url = `${PROTOCOL}://${HOST}/${MODEL_BASE_PATH}/${MODEL_NAME}/v1/completions`;
    
    const payload = JSON.stringify({
        model: MODEL_PAYLOAD_ID,
        prompt: "Write a short story about a robot learning to paint. The robot",
        max_tokens: MAX_TOKENS,
        temperature: 0.7
    });
    
    const params = {
        headers: {
            "Content-Type": "application/json",
        },
        timeout: "60s"
    };
    
    if (AUTH_HEADER) {
        params.headers["Authorization"] = AUTH_HEADER;
    }
    
    const startTime = Date.now();
    const response = http.post(url, payload, params);
    const latency = Date.now() - startTime;
    
    inferenceLatency.add(latency);
    
    const success = check(response, {
        "status_success": (r) => r.status >= 200 && r.status < 300,
        "has_choices": (r) => {
            try {
                const body = JSON.parse(r.body);
                return body.choices && body.choices.length > 0;
            } catch {
                return false;
            }
        },
        "response_time_ok": (r) => r.timings.duration < 5000,
    });
    
    inferenceSuccess.add(success ? 1 : 0);
    
    if (success) {
        try {
            const body = JSON.parse(response.body);
            if (body.usage && body.usage.completion_tokens) {
                tokensGenerated.add(body.usage.completion_tokens);
            }
        } catch {
            // Ignore parsing errors
        }
    }
    
    sleep(0.5);
}

export function setup() {
    console.log("=== Inference Latency Benchmark Setup ===");
    console.log(`Host: ${HOST}`);
    console.log(`Model: ${MODEL_NAME}`);
    console.log(`Max Tokens: ${MAX_TOKENS}`);
    console.log(`VUs: ${VUS}`);
    console.log(`Iterations: ${ITERATIONS}`);
    console.log(`Auth: ${AUTH_HEADER ? "Enabled" : "None"}`);
    console.log("==========================================");
}

export function teardown(data) {
    console.log("=== Inference Latency Benchmark Complete ===");
}
