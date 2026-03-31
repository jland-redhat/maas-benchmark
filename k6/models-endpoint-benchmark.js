import http from "k6/http";
import { check, sleep } from "k6";
import { Counter, Rate, Trend } from "k6/metrics";

// ========================================
// Configuration
// ========================================
const HOST = __ENV.HOST || "maas.example.com";
const PROTOCOL = __ENV.PROTOCOL || "https";
const AUTH_HEADER = __ENV.AUTH_HEADER || "";
const WITH_FILTER = __ENV.WITH_FILTER === "true";
const SUBSCRIPTION_HEADER = __ENV.SUBSCRIPTION_HEADER || "";
const VUS = Number(__ENV.VUS || 5);
const ITERATIONS = Number(__ENV.ITERATIONS || 50);

// ========================================
// Custom metrics
// ========================================
const listSuccess = new Rate("list_success");
const listLatency = new Trend("list_latency", true);
const modelCount = new Trend("model_count", true);

// ========================================
// Scenario configuration
// ========================================
export const options = {
    scenarios: {
        models_list: {
            executor: "shared-iterations",
            exec: "modelsListTest",
            vus: VUS,
            iterations: ITERATIONS,
            maxDuration: "10m"
        }
    },
    thresholds: {
        http_req_duration: ["p(95)<5000"],
        http_req_failed: ["rate<0.1"],
        list_success: ["rate>0.9"],
    },
    insecureSkipTLSVerify: true,
};

// ========================================
// Test function
// ========================================
export function modelsListTest() {
    const url = `${PROTOCOL}://${HOST}/v1/models`;
    
    const params = {
        headers: {
            "Content-Type": "application/json",
        },
        timeout: "30s"
    };
    
    if (AUTH_HEADER) {
        params.headers["Authorization"] = AUTH_HEADER;
    }
    
    if (WITH_FILTER && SUBSCRIPTION_HEADER) {
        params.headers["X-MaaS-Subscription"] = SUBSCRIPTION_HEADER;
    }
    
    const startTime = Date.now();
    const response = http.get(url, params);
    const latency = Date.now() - startTime;
    
    listLatency.add(latency);
    
    const success = check(response, {
        "status_success": (r) => r.status >= 200 && r.status < 300,
        "has_data": (r) => {
            try {
                const body = JSON.parse(r.body);
                return body.data !== undefined || body.models !== undefined;
            } catch {
                return false;
            }
        },
        "response_time_ok": (r) => r.timings.duration < 5000,
    });
    
    listSuccess.add(success ? 1 : 0);
    
    if (success) {
        try {
            const body = JSON.parse(response.body);
            const count = (body.data || body.models || []).length;
            modelCount.add(count);
        } catch {
            // Ignore parsing errors
        }
    }
    
    sleep(0.2);
}

export function setup() {
    console.log("=== /v1/models Endpoint Benchmark Setup ===");
    console.log(`Host: ${HOST}`);
    console.log(`Auth: ${AUTH_HEADER ? "Enabled" : "None"}`);
    console.log(`Filter: ${WITH_FILTER ? SUBSCRIPTION_HEADER : "None"}`);
    console.log(`VUs: ${VUS}`);
    console.log(`Iterations: ${ITERATIONS}`);
    console.log("=============================================");
}

export function teardown() {
    console.log("=== /v1/models Endpoint Benchmark Complete ===");
}
