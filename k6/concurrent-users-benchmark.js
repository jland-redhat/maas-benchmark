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
const API_KEY = __ENV.API_KEY || "";
const VUS = Number(__ENV.VUS || 10);
const DURATION = __ENV.DURATION || "2m";

// ========================================
// Custom metrics
// ========================================
const successRate = new Rate("success_rate");
const inferenceLatency = new Trend("inference_latency", true);
const errorCounter = new Counter("errors");
const requestCounter = new Counter("total_requests");

// ========================================
// Scenario configuration
// ========================================
export const options = {
    scenarios: {
        sustained_load: {
            executor: "constant-vus",
            exec: "sustainedLoadTest",
            vus: VUS,
            duration: DURATION
        }
    },
    thresholds: {
        http_req_duration: ["p(95)<10000"],
        http_req_failed: ["rate<0.2"],
        success_rate: ["rate>0.8"],
    },
    insecureSkipTLSVerify: true,
};

// ========================================
// Test function
// ========================================
export function sustainedLoadTest() {
    const url = `${PROTOCOL}://${HOST}/${MODEL_BASE_PATH}/${MODEL_NAME}/v1/completions`;
    
    const prompts = [
        "Explain quantum computing in simple terms.",
        "Write a haiku about artificial intelligence.",
        "Describe the process of photosynthesis.",
        "What are the benefits of renewable energy?",
        "How does machine learning work?",
    ];
    
    const prompt = prompts[Math.floor(Math.random() * prompts.length)];
    
    const payload = JSON.stringify({
        model: MODEL_PAYLOAD_ID,
        prompt: prompt,
        max_tokens: 50,
        temperature: 0.7
    });
    
    const params = {
        headers: {
            "Content-Type": "application/json",
            "Authorization": `Bearer ${API_KEY}`
        },
        timeout: "60s"
    };
    
    requestCounter.add(1);
    
    const startTime = Date.now();
    const response = http.post(url, payload, params);
    const latency = Date.now() - startTime;
    
    inferenceLatency.add(latency);
    
    const success = check(response, {
        "status_success": (r) => r.status >= 200 && r.status < 300,
        "has_response": (r) => {
            try {
                const body = JSON.parse(r.body);
                return body.choices && body.choices.length > 0;
            } catch {
                return false;
            }
        },
        "latency_ok": (r) => r.timings.duration < 10000,
    });
    
    if (success) {
        successRate.add(1);
    } else {
        successRate.add(0);
        errorCounter.add(1);
        
        if (response.status === 429) {
            console.log(`Rate limited (429) at VU ${__VU}`);
        } else if (response.status >= 500) {
            console.log(`Server error (${response.status}) at VU ${__VU}`);
        } else if (response.status === 401 || response.status === 403) {
            console.log(`Auth error (${response.status}) at VU ${__VU}`);
        }
    }
    
    // Think time between requests (simulates real user behavior)
    sleep(Math.random() * 2 + 0.5);
}

export function setup() {
    console.log("=== Concurrent User Breaking Point Benchmark ===");
    console.log(`Host: ${HOST}`);
    console.log(`Model: ${MODEL_NAME}`);
    console.log(`VUs: ${VUS}`);
    console.log(`Duration: ${DURATION}`);
    console.log(`API Key: ${API_KEY ? "Configured" : "Missing!"}`);
    console.log("=================================================");
    
    if (!API_KEY) {
        console.error("WARNING: No API key configured. Tests will fail authentication.");
    }
}

export function teardown(data) {
    console.log("=== Concurrent User Benchmark Complete ===");
}
