import http from "k6/http";
import { check, sleep } from "k6";
import { Counter, Rate, Trend } from "k6/metrics";

// ========================================
// Configuration via environment variables
// ========================================
const CLUSTER_DOMAIN = __ENV.CLUSTER_DOMAIN || "";
const HOST = __ENV.HOST || `maas.${CLUSTER_DOMAIN}`;
const PROTOCOL = __ENV.PROTOCOL || "http";
const MODEL_NAME = __ENV.MODEL_NAME || "";
// Base path before model name in URL (default: maas-benchmarking). Full path: /${MODEL_BASE_PATH}/${model}/v1/completions
const MODEL_BASE_PATH = __ENV.MODEL_BASE_PATH || "maas-benchmarking";
// Model id sent in request body (some backends expect e.g. "facebook/opt-125m" for simulator)
const MODEL_PAYLOAD_ID = __ENV.MODEL_PAYLOAD_ID || MODEL_NAME || "default-model";
// Subscription header required by MaaS gateway (e.g. maas-benchmark-subscription)
const MAAS_SUBSCRIPTION_HEADER = __ENV.MAAS_SUBSCRIPTION_HEADER || "maas-benchmark-subscription";
const MODE = __ENV.MODE || "burst"; // "burst" | "soak" | "rate-limit-test"

// Burst configuration
const BURST_ITERATIONS = Number(__ENV.BURST_ITERATIONS || 100);
const BURST_VUS = Number(__ENV.BURST_VUS || 10);

// Soak configuration
const SOAK_DURATION = __ENV.SOAK_DURATION || "5m";
const SOAK_RATE_FREE = Number(__ENV.SOAK_RATE_FREE || 2);
const SOAK_RATE_PREMIUM = Number(__ENV.SOAK_RATE_PREMIUM || 5);

// Rate limiting test configuration
const RATE_LIMIT_DURATION = __ENV.RATE_LIMIT_DURATION || "2m";
const RATE_LIMIT_VUS = Number(__ENV.RATE_LIMIT_VUS || 50);

// Request configuration
const MAX_TOKENS_FREE = Number(__ENV.MAX_TOKENS_FREE || 50);
const MAX_TOKENS_PREMIUM = Number(__ENV.MAX_TOKENS_PREMIUM || 100);
const REQUEST_TIMEOUT = __ENV.REQUEST_TIMEOUT || "30s";

// Token configuration
const TOKEN_FILE_PATH = __ENV.TOKEN_FILE_PATH || "../tokens/all/all_tokens.json";
const USE_SAMPLE_TOKENS = (__ENV.USE_SAMPLE_TOKENS || "false").toLowerCase() === "true";
const SAMPLE_SIZE = Number(__ENV.SAMPLE_SIZE || 50);

// ========================================
// Custom metrics
// ========================================
const authFailures = new Counter("auth_failures");
const rateLimitHits = new Counter("rate_limit_hits");
const tokenLimitHits = new Counter("token_limit_hits");
const responseTimeTrend = new Trend("response_time", true);
const successRate = new Rate("success_rate");

// ========================================
// Load and prepare tokens
// ========================================
let tokens = { free: [], premium: [] };

// Load tokens from file or use sample data
function loadTokens() {
    if (USE_SAMPLE_TOKENS) {
        // Generate sample API keys for testing without provisioned keys
        console.log("Using sample tokens for testing");
        for (let i = 1; i <= SAMPLE_SIZE; i++) {
            tokens.free.push({
                user_id: `freeuser${i}`,
                token: `sample_free_token_${i}`,
                tier: "free"
            });
            tokens.premium.push({
                user_id: `premiumuser${i}`,
                token: `sample_premium_token_${i}`,
                tier: "premium"
            });
        }
    } else {
        // Load real tokens from file
        try {
            const tokenData = JSON.parse(open(TOKEN_FILE_PATH));
            tokens.free = tokenData.free || [];
            tokens.premium = tokenData.premium || [];
            console.log(`Loaded ${tokens.free.length} free tokens and ${tokens.premium.length} premium tokens`);
        } catch (error) {
            console.error(`Failed to load tokens from ${TOKEN_FILE_PATH}: ${error}`);
            console.log("Run 'scripts/provision-api-keys.sh' first or set USE_SAMPLE_TOKENS=true for testing");
            throw new Error("Token loading failed");
        }
    }

    if (tokens.free.length === 0 && tokens.premium.length === 0) {
        throw new Error("No tokens available for testing");
    }
}

loadTokens();

// ========================================
// Scenario configurations
// ========================================
function createScenarios() {
    let scenarios = {};

    if (MODE === "burst") {
        // Burst mode: high concurrent load for a short period
        if (tokens.free.length > 0) {
            scenarios.free_burst = {
                executor: "shared-iterations",
                exec: "freeTierTest",
                vus: Math.min(BURST_VUS, tokens.free.length),
                iterations: BURST_ITERATIONS,
                maxDuration: "10m"
            };
        }

        if (tokens.premium.length > 0) {
            scenarios.premium_burst = {
                executor: "shared-iterations",
                exec: "premiumTierTest",
                vus: Math.min(BURST_VUS, tokens.premium.length),
                iterations: BURST_ITERATIONS,
                maxDuration: "10m"
            };
        }
    } else if (MODE === "soak") {
        // Soak mode: sustained load over a longer period
        if (tokens.free.length > 0) {
            scenarios.free_soak = {
                executor: "constant-arrival-rate",
                exec: "freeTierTest",
                rate: SOAK_RATE_FREE,
                timeUnit: "1s",
                duration: SOAK_DURATION,
                preAllocatedVUs: Math.min(10, tokens.free.length),
                maxVUs: Math.min(50, tokens.free.length)
            };
        }

        if (tokens.premium.length > 0) {
            scenarios.premium_soak = {
                executor: "constant-arrival-rate",
                exec: "premiumTierTest",
                rate: SOAK_RATE_PREMIUM,
                timeUnit: "1s",
                duration: SOAK_DURATION,
                preAllocatedVUs: Math.min(10, tokens.premium.length),
                maxVUs: Math.min(50, tokens.premium.length)
            };
        }
    } else if (MODE === "rate-limit-test") {
        // Rate limit testing: designed to hit limits
        if (tokens.free.length > 0) {
            scenarios.free_rate_limit = {
                executor: "constant-vus",
                exec: "freeTierRateLimitTest",
                vus: Math.min(RATE_LIMIT_VUS, tokens.free.length),
                duration: RATE_LIMIT_DURATION
            };
        }

        if (tokens.premium.length > 0) {
            scenarios.premium_rate_limit = {
                executor: "constant-vus",
                exec: "premiumTierRateLimitTest",
                vus: Math.min(RATE_LIMIT_VUS, tokens.premium.length),
                duration: RATE_LIMIT_DURATION
            };
        }
    }

    return scenarios;
}

export const options = {
    scenarios: createScenarios(),
    thresholds: {
        http_req_duration: ["p(95)<5000"], // 95% of requests under 5s
        http_req_failed: ["rate<0.1"],     // Less than 10% failures
        success_rate: ["rate>0.9"],       // More than 90% success
    },
    insecureSkipTLSVerify: true, // Skip TLS verification for self-signed certs
};

// ========================================
// Utility functions
// ========================================
function getRandomToken(tier) {
    const tierTokens = tokens[tier];
    if (tierTokens.length === 0) {
        throw new Error(`No ${tier} tokens available`);
    }
    return tierTokens[Math.floor(Math.random() * tierTokens.length)];
}

function buildModelUrl(modelName) {
    if (modelName) {
        // Transform for URL: facebook/opt-125m -> facebook-opt-125m-simulated; already MaaSModel name (e.g. facebook-opt-125m-simulated) left as-is
        const base = modelName.replace(/\//g, "-");
        const urlModelName = base.endsWith("-simulated") ? base : base + "-simulated";
        return `${PROTOCOL}://${HOST}/${MODEL_BASE_PATH}/${urlModelName}/v1/completions`;
    }
    return `${PROTOCOL}://${HOST}/${MODEL_BASE_PATH}/v1/completions`;
}

function makeInferenceRequest(token, prompt, maxTokens, tier) {
    const modelUrl = buildModelUrl(MODEL_NAME);

    // /v1/completions format: model, prompt, max_tokens (required by MaaS gateway)
    const payload = JSON.stringify({
        model: MODEL_PAYLOAD_ID,
        prompt: prompt,
        max_tokens: maxTokens
    });

    const headers = {
        "Authorization": `Bearer ${token.token}`,
        "Content-Type": "application/json",
        "x-maas-subscription": MAAS_SUBSCRIPTION_HEADER
    };

    const response = http.post(modelUrl, payload, {
        headers,
        timeout: REQUEST_TIMEOUT
    });

    // Record metrics
    responseTimeTrend.add(response.timings.duration);

    // Check response status and update metrics
    const success = response.status >= 200 && response.status < 400;
    successRate.add(success);

    const checks = {
        [`${tier}_status_success`]: (r) => r.status >= 200 && r.status < 400,
        [`${tier}_response_time_ok`]: (r) => r.timings.duration < 30000,
    };

    // Check for specific error conditions
    if (response.status === 401 || response.status === 403) {
        authFailures.add(1);
        checks[`${tier}_auth_failure`] = (r) => false;
    } else if (response.status === 429) {
        // Check if it's rate limiting or token limiting
        const responseBody = response.body;
        if (responseBody && responseBody.includes("token")) {
            tokenLimitHits.add(1);
            checks[`${tier}_token_limit_hit`] = (r) => r.status === 429;
        } else {
            rateLimitHits.add(1);
            checks[`${tier}_rate_limit_hit`] = (r) => r.status === 429;
        }
    }

    check(response, checks);

    // Debug logging
    if (__ENV.DEBUG === "true") {
        console.log(`[${tier}] ${token.user_id}: Status ${response.status}, URL: ${modelUrl}`);
        if (response.status !== 200) {
            console.log(`[${tier}] ${token.user_id}: Response body: ${response.body.substring(0, 200)}...`);
        }
    }

    return response;
}

// ========================================
// Test scenarios
// ========================================
export function freeTierTest() {
    const token = getRandomToken("free");
    const prompt = `Free tier test request from ${token.user_id}`;

    makeInferenceRequest(token, prompt, MAX_TOKENS_FREE, "free");

    // No sleep - wait for response before next request (default k6 behavior)
}

export function premiumTierTest() {
    const token = getRandomToken("premium");
    const prompt = `Premium tier test request from ${token.user_id}`;

    makeInferenceRequest(token, prompt, MAX_TOKENS_PREMIUM, "premium");

    // No sleep - wait for response before next request (default k6 behavior)
}

export function freeTierRateLimitTest() {
    const token = getRandomToken("free");
    const prompt = `Rate limit test from ${token.user_id}`;

    makeInferenceRequest(token, prompt, MAX_TOKENS_FREE, "free");

    // No sleep in rate limit test - try to hit limits
}

export function premiumTierRateLimitTest() {
    const token = getRandomToken("premium");
    const prompt = `Rate limit test from ${token.user_id}`;

    makeInferenceRequest(token, prompt, MAX_TOKENS_PREMIUM, "premium");

    // No sleep in rate limit test - try to hit limits
}

// ========================================
// Test lifecycle hooks
// ========================================
export function setup() {
    console.log("=== MaaS Performance Test Setup ===");
    console.log(`Mode: ${MODE}`);
    console.log(`Host: ${HOST}`);
    console.log(`Protocol: ${PROTOCOL}`);
    console.log(`Model: ${MODEL_NAME || "auto-detect"}`);
    console.log(`Free tokens: ${tokens.free.length}`);
    console.log(`Premium tokens: ${tokens.premium.length}`);

    if (__ENV.DEBUG === "true") {
        const testUrl = buildModelUrl(MODEL_NAME);
        console.log(`DEBUG: Model URL: ${testUrl}`);
        if (tokens.free.length > 0) {
            console.log(`DEBUG: Free token user: ${tokens.free[0].user_id}`);
        }
        if (tokens.premium.length > 0) {
            console.log(`DEBUG: Premium token user: ${tokens.premium[0].user_id}`);
        }
    }
    console.log("=====================================");
}

export function teardown() {
    console.log("=== MaaS Performance Test Complete ===");
    console.log(`Auth failures: ${authFailures.count}`);
    console.log(`Rate limit hits: ${rateLimitHits.count}`);
    console.log(`Token limit hits: ${tokenLimitHits.count}`);
    console.log("=======================================");
}