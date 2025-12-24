// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.20;

import "../contract/llm-quorum.sol";

/**
 * @title LLMQuorumTest
 * @notice A simple test contract to interact with the LLM Quorum service
 * @dev Demonstrates basic request/callback flow with multi-model consensus
 */
contract LLMQuorumTest is ILLMQuorumCallback {
    // ============================================================
    //                       STATE VARIABLES
    // ============================================================

    address public owner;
    LLMQuorum public quorumService;

    string public lastResult;

    // ============================================================
    //                          EVENTS
    // ============================================================

    event RequestSubmitted(uint256 indexed requestId, address indexed sender, bytes32 configHash);
    event QuorumResult(uint256 indexed requestId, address indexed sender, string result);
    event ServiceAddressUpdated(address indexed newAddress);

    // ============================================================
    //                         MODIFIERS
    // ============================================================

    modifier onlyOwner() {
        require(msg.sender == owner, "LLMQuorumTest: permission denied");
        _;
    }

    // ============================================================
    //                        CONSTRUCTOR
    // ============================================================

    /**
     * @notice Initialize the test contract
     * @param _quorumService Address of the LLM Quorum service contract
     */
    constructor(address _quorumService) {
        require(_quorumService != address(0), "LLMQuorumTest: invalid service address");

        owner = msg.sender;
        quorumService = LLMQuorum(payable(_quorumService));
    }

    // ============================================================
    //                      ADMIN FUNCTIONS
    // ============================================================

    /**
     * @notice Update the LLM Quorum service contract address
     * @param _quorumService New service address
     */
    function setQuorumServiceAddress(address _quorumService) external onlyOwner {
        require(_quorumService != address(0), "LLMQuorumTest: invalid service address");
        quorumService = LLMQuorum(payable(_quorumService));
        emit ServiceAddressUpdated(_quorumService);
    }

    // ============================================================
    //                      MAIN FUNCTIONS
    // ============================================================

    /**
     * @notice Submit a new LLM Quorum request to multiple models
     * @param configHash Hash of the config/prompt file
     * @param userInput The user's input string
     * @param models Array of models to query for consensus
     * @return requestId The LLM Quorum service request ID
     */
    function newRequest(
        bytes32 configHash,
        string calldata userInput,
        LLMQuorum.ModelInfo[] calldata models
    ) external payable returns (uint256 requestId) {
        // Build the input JSON string
        string memory input = string(abi.encodePacked(
            '{"user_input":"',
            userInput,
            '"}'
        ));

        // Call the LLM Quorum service
        // Parameters: prompt, input, models, quorumThreshold, redundancy, returnContentWithinResultTag, storeResultOffchain, callback, args
        requestId = quorumService.newRequest{value: msg.value}(
            configHash,                    // prompt hash
            input,                         // JSON input
            models,                        // array of models to query
            0,                             // quorum threshold (0 = majority)
            1,                             // redundancy of 1 per model
            true,                          // return content within result tag
            false,                         // don't store result off-chain
            "handleQuorumResult",          // callback function
            abi.encode(msg.sender)         // encode sender address as args
        );

        emit RequestSubmitted(requestId, msg.sender, configHash);

        return requestId;
    }

    /**
     * @notice Submit a simple request using default models (GPT-4 and Claude)
     * @param configHash Hash of the config/prompt file
     * @param userInput The user's input string
     * @return requestId The LLM Quorum service request ID
     */
    function newRequestWithDefaultModels(
        bytes32 configHash,
        string calldata userInput
    ) external payable returns (uint256 requestId) {
        // Build the input JSON string
        string memory input = string(abi.encodePacked(
            '{"user_input":"',
            userInput,
            '"}'
        ));

        // Create a dynamic array of models
        LLMQuorum.ModelInfo[] memory models = new LLMQuorum.ModelInfo[](3);
        models[0] = LLMQuorum.ModelInfo({
            platform: bytes32("openai"),
            model: bytes32("gpt-5")
        });
        models[1] = LLMQuorum.ModelInfo({
            platform: bytes32("deepseek"),
            model: bytes32("deepseek-chat")
        });
        models[2] = LLMQuorum.ModelInfo({
          platform: bytes32("anthropic"),
          model: bytes32("claude-sonnet-4-5-20250929")
        });

        // Call the LLM Quorum service
        requestId = quorumService.newRequest{value: msg.value}(
            configHash,                    // prompt hash
            input,                         // JSON input
            models,                        // array of models to query
            3,                             // quorum threshold (all 3 models must agree)
            1,                             // redundancy of 1 per model
            true,                          // return content within result tag
            false,                         // don't store result off-chain
            "handleQuorumResult",          // callback function
            abi.encode(msg.sender)         // encode sender address as args
        );

        emit RequestSubmitted(requestId, msg.sender, configHash);

        return requestId;
    }

    /**
     * @notice Callback function called by LLM Quorum service when consensus is reached
     * @param requestId The original request ID
     * @param result The consensus result string
     * @param args Encoded callback arguments (sender address)
     */
    function handleQuorumResult(
        uint256 requestId,
        string calldata result,
        bytes calldata args
    ) external override {
        require(msg.sender == address(quorumService), "LLMQuorumTest: only Quorum service can call this");

        // Decode the sender address from args
        address sender = abi.decode(args, (address));

        // Store the result
        lastResult = result;

        emit QuorumResult(requestId, sender, result);
    }

    // ============================================================
    //                    VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get the last result received
     * @return The last LLM Quorum result string
     */
    function getLastResult() external view returns (string memory) {
        return lastResult;
    }
}
