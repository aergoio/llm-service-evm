# HPP LLM Service

A decentralized LLM (Large Language Model) service for the HPP Network

Smart contracts can request LLM completions, which are processed by authorized off-chain nodes and returned via callbacks

## Components

### Smart Contract

[Solidity contract](contract/llm-service.sol) that:
- Accepts LLM requests from other contracts (paid in native token)
- Manages authorized nodes and pricing per platform/model
- Supports redundancy (multiple nodes must agree on result)
- Fires callbacks with results to the requesting contract

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

From another Solidity contract:

```solidity
import "./llm-service.sol";

contract MyContract is ILLMServiceCallback {
    ILLMService public llmService;

    function askLLM(bytes32 configHash, string calldata userInput) external payable {
        // Build input JSON with values (can reference off-chain stored content by hash)
        string memory input = string(abi.encodePacked(
            '{"user_input":"', userInput, '"}'
        ));

        // Call the LLM service
        uint256 requestId = llmService.newRequest{value: msg.value}(
            bytes32(0),          // platform (use from config)
            bytes32(0),          // model (use from config)
            configHash,          // SHA256 hash of prompt config
            input,               // JSON input string
            1,                   // redundancy (nodes that must agree)
            true,                // extract content from <result> tags
            false,               // store result on-chain (not off-chain)
            "handleLLMResult",   // callback function name
            abi.encode(msg.sender) // extra args passed to callback
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

See the [complete example contract](example/example-usage.sol) for a working implementation.

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
