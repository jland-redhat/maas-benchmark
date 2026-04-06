import http from "k6/http";
import { check, sleep } from "k6";
import { Counter, Rate, Trend } from "k6/metrics";

// ========================================
// Configuration
// ========================================
const HOST = __ENV.HOST || "maas.example.com";
const PROTOCOL = __ENV.PROTOCOL || "https";
const AUTH_TOKEN = __ENV.AUTH_TOKEN || "";
const MODE = __ENV.MODE || "api_key_create";
const VUS = Number(__ENV.VUS || 1);
const ITERATIONS = Number(__ENV.ITERATIONS || 100);
const DURATION = __ENV.DURATION || "30s";
const TOKEN_FILE_PATH = __ENV.TOKEN_FILE_PATH || "../tokens/api-key-benchmark/all_tokens.json";

// ========================================
// Custom metrics
// ========================================
const createSuccess = new Rate("create_success");
const validateSuccess = new Rate("validate_success");
const searchSuccess = new Rate("search_success");
const createLatency = new Trend("create_latency", true);
const validateLatency = new Trend("validate_latency", true);
const searchLatency = new Trend("search_latency", true);

// ========================================
// Load tokens for validation testing
// ========================================
let tokens = [];

function loadTokens() {
    try {
        const tokenData = JSON.parse(open(TOKEN_FILE_PATH));
        tokens = tokenData.free || [];
        console.log(`Loaded ${tokens.length} tokens for validation testing`);
    } catch (error) {
        console.log(`Token file not available: ${error}`);
    }
}

if (MODE === "api_key_validate") {
    loadTokens();
}

// ========================================
// Scenario configurations
// ========================================
function createScenarios() {
    if (MODE === "api_key_create") {
        return {
            create_keys: {
                executor: "shared-iterations",
                exec: "createKeyTest",
                vus: VUS,
                iterations: ITERATIONS,
                maxDuration: "30m"
            }
        };
    } else if (MODE === "api_key_validate") {
        return {
            validate_keys: {
                executor: "constant-vus",
                exec: "validateKeyTest",
                vus: VUS,
                duration: DURATION
            }
        };
    } else if (MODE === "api_key_search") {
        return {
            search_keys: {
                executor: "shared-iterations",
                exec: "searchKeyTest",
                vus: VUS,
                iterations: ITERATIONS,
                maxDuration: "10m"
            }
        };
    }
    return {};
}

export const options = {
    scenarios: createScenarios(),
    thresholds: {
        http_req_duration: ["p(95)<5000"],
        http_req_failed: ["rate<0.1"],
    },
    insecureSkipTLSVerify: true,
};

// ========================================
// Test functions
// ========================================

export function createKeyTest() {
    const url = `${PROTOCOL}://${HOST}/maas-api/v1/api-keys`;
    const payload = JSON.stringify({
        name: `benchmark-key-${__VU}-${__ITER}`,
        expiresIn: "1h"
    });
    
    const params = {
        headers: {
            "Content-Type": "application/json",
            "Authorization": `Bearer ${AUTH_TOKEN}`
        },
        timeout: "30s"
    };
    
    const startTime = Date.now();
    const response = http.post(url, payload, params);
    const latency = Date.now() - startTime;
    
    createLatency.add(latency);
    
    const success = check(response, {
        "create_status_success": (r) => r.status >= 200 && r.status < 300,
        "create_has_key": (r) => {
            try {
                const body = JSON.parse(r.body);
                return body.key && body.key.startsWith("sk-oai-");
            } catch {
                return false;
            }
        }
    });
    
    createSuccess.add(success ? 1 : 0);
    
    sleep(0.1);
}

export function validateKeyTest() {
    if (tokens.length === 0) {
        console.log("No tokens available for validation testing");
        return;
    }
    
    const token = tokens[Math.floor(Math.random() * tokens.length)];
    const url = `${PROTOCOL}://${HOST}/internal/v1/api-keys/validate`;
    const payload = JSON.stringify({
        key: token.token
    });
    
    const params = {
        headers: {
            "Content-Type": "application/json"
        },
        timeout: "10s"
    };
    
    const startTime = Date.now();
    const response = http.post(url, payload, params);
    const latency = Date.now() - startTime;
    
    validateLatency.add(latency);
    
    const success = check(response, {
        "validate_status_success": (r) => r.status >= 200 && r.status < 300,
        "validate_response_valid": (r) => {
            try {
                const body = JSON.parse(r.body);
                return body.valid === true || body.userId !== undefined;
            } catch {
                return false;
            }
        }
    });
    
    validateSuccess.add(success ? 1 : 0);
}

export function searchKeyTest() {
    const url = `${PROTOCOL}://${HOST}/maas-api/v1/api-keys/search`;
    const payload = JSON.stringify({
        limit: 10,
        offset: 0
    });
    
    const params = {
        headers: {
            "Content-Type": "application/json",
            "Authorization": `Bearer ${AUTH_TOKEN}`
        },
        timeout: "30s"
    };
    
    const startTime = Date.now();
    const response = http.post(url, payload, params);
    const latency = Date.now() - startTime;
    
    searchLatency.add(latency);
    
    const success = check(response, {
        "search_status_success": (r) => r.status >= 200 && r.status < 300,
        "search_has_results": (r) => {
            try {
                const body = JSON.parse(r.body);
                return Array.isArray(body.keys) || body.total !== undefined;
            } catch {
                return false;
            }
        }
    });
    
    searchSuccess.add(success ? 1 : 0);
    
    sleep(0.2);
}

export function setup() {
    console.log("=== API Key Benchmark Setup ===");
    console.log(`Mode: ${MODE}`);
    console.log(`Host: ${HOST}`);
    console.log(`VUs: ${VUS}`);
    if (MODE === "api_key_create" || MODE === "api_key_search") {
        console.log(`Iterations: ${ITERATIONS}`);
    } else {
        console.log(`Duration: ${DURATION}`);
    }
    console.log("================================");
}

export function teardown() {
    console.log("=== API Key Benchmark Complete ===");
}
