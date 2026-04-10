# HPP LLM Service

A decentralized LLM (Large Language Model) service for the HPP Network

Smart contracts can request LLM completions, which are processed by authorized off-chain nodes and returned via callbacks

## Components

### Smart Contracts

[LLM Service](contract/llm-service.sol):
- Accepts LLM requests from other contracts
- Manages authorized nodes and pricing per platform/model
- Supports redundancy (multiple nodes must agree on result)
- Fires callbacks with results to the requesting contract
- Payments are done using accepted ERC-20 tokens, either via `transferAndCall` or `approve` + `transferFrom`

[LLM Quorum](contract/llm-quorum.sol):
- Runs the same prompt and input across several models
- Fires callbacks with results to the requesting contract when the consensus is reached

### Backend Nodes

[Off-chain Node.js service](nodes/llm-service.js) that:
- Listens for `NewRequest` events from the contract
- Fetches config and inputs from storage
- Calls LLM APIs (OpenAI, Anthropic, etc.)
- Submits results back to the contract

### Supported Platforms

- OpenAI (GPT-5, etc.)
- Anthropic (Claude)
- Google Gemini
- Grok (xAI)
- Groq
- DeepSeek
- Alibaba (Qwen)
- Moonshot (Kimi)
- Zhipu (GLM)
- Perplexity

## Usage

### Running the Node

```bash
cd nodes
npm install
node llm-service.js hpp-sepolia   # or hpp-mainnet, local, etc.
```

The node generates an account on first run (saved to `nodes/account.data`). Add the printed address as an authorized node in the contract

### Supported Networks

- `hpp-mainnet` - HPP Network mainnet
- `hpp-sepolia` - HPP Network testnet
- `mainnet` - Ethereum mainnet
- `sepolia` - Ethereum Sepolia testnet
- `polygon` - Polygon mainnet
- `arbitrum` - Arbitrum One
- `base` - Base mainnet
- `local` - Local development (requires `LLM_SERVICE_CONTRACT` env var)

### Contract Integration

Callers must be contract (not EOAs). Use an ERC-20 that the service accepts. Amount must be at least `getPriceInToken(platform, model, token).amount * redundancy` (quorum: sum per model × redundancy). Excess payment is not refunded.

#### Approve + `newRequest`

From another contract:

```solidity
import "./llm-service.sol";

contract MyContract is ILLMServiceCallback {
    ILLMService public llmService;

    function askLLM(
        bytes32 configHash,
        string calldata userInput,
        address token,
        uint256 amount
    ) external returns (uint256 requestId) {

        // Pull ERC-20 from caller, then let LLMService pull from this contract
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "pull failed");
        require(IERC20(token).approve(address(llmService), amount), "approve failed");

        // Build input JSON with values (can reference off-chain stored content by hash)
        string memory input = string(abi.encodePacked(
            '{"user_input":"', userInput, '"}'
        ));

        // Call the LLM service
        requestId = llmService.newRequest(
            RequestArgs({
                platform: bytes32(0),                    // platform (use from config)
                model: bytes32(0),                       // model (use from config)
                prompt: configHash,                      // SHA256 hash of prompt config
                input: input,                            // JSON input string
                redundancy: 1,                           // redundancy (nodes that must agree)
                returnContentWithinResultTag: true,      // extract content from <result> tags
                storeResultOffchain: false,              // store result on-chain (not off-chain)
                callback: "handleLLMResult",             // callback function name
                args: abi.encode(msg.sender)             // extra args passed to callback
            }),
            token,                                       // ERC-20 payment token
            amount                                       // must cover price × redundancy; excess not refunded
        );
    }

    function handleLLMResult(
        uint256 requestId,
        string calldata result,
        bytes calldata args
    ) external override {
        require(msg.sender == address(llmService), "unauthorized");

        // Decode args and use result
        address sender = abi.decode(args, (address));
        // ... do something with result
    }
}
```

#### `transferAndCall`

```solidity
// IERC20 — token must implement transferAndCall(address,uint256,bytes)
interface IERC20 {
    function transferAndCall(address to, uint256 amount, bytes calldata data) external returns (bool);
}

// Inside your ILLMServiceCallback contract (after pulling `amount` from the user to address(this)):
// Build input JSON (same as above), then encode the same payload as `newRequest`:
bytes memory data = abi.encode(
    RequestArgs({
        platform: bytes32(0),                    // platform (use from config)
        model: bytes32(0),                       // model (use from config)
        prompt: configHash,                      // SHA256 hash of prompt config
        input: input,                            // JSON input string
        redundancy: 1,                           // redundancy (nodes that must agree)
        returnContentWithinResultTag: true,      // extract content from <result> tags
        storeResultOffchain: false,              // store result on-chain (not off-chain)
        callback: "handleLLMResult",             // callback function name
        args: abi.encode(msg.sender)             // extra args passed to callback
    })
);

bool success = IERC20(token).transferAndCall(address(llmService), amount, data);
require(success, "transferAndCall failed");

uint256 requestId = LLMService(address(llmService)).lastRequestId();
```

Working examples: [single-model](example/llm-service-example-usage.sol), [quorum](example/llm-quorum-example-usage.sol)


### Prompt Config Format

Store your prompt config off-chain and reference it by SHA256 hash. The config format:

```
model: anthropic/claude-sonnet-4-20250514
You are a helpful assistant

User input: {{user_input}}

Please respond with your answer inside <result></result> tags
```

- First line (optional): `model: platform/model` to specify the LLM
- Remaining lines: The prompt template
- Use `{{key}}` placeholders that get replaced with values from the input JSON
