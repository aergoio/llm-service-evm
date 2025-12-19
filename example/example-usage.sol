// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./llm-service.sol";

/**
 * @title LLMTest
 * @notice A simple test contract to interact with the LLM service
 * @dev Demonstrates basic request/callback flow with the LLM oracle
 */
contract LLMTest is ILLMServiceCallback {
    // ============================================================
    //                       STATE VARIABLES
    // ============================================================

    address public owner;
    ILLMService public llmService;

    string public lastResult;

    // ============================================================
    //                          EVENTS
    // ============================================================

    event RequestSubmitted(uint256 indexed requestId, address indexed sender, bytes32 configHash);
    event LLMResult(uint256 indexed requestId, address indexed sender, string result);
    event ServiceAddressUpdated(address indexed newAddress);

    // ============================================================
    //                         MODIFIERS
    // ============================================================

    modifier onlyOwner() {
        require(msg.sender == owner, "LLMTest: permission denied");
        _;
    }

    // ============================================================
    //                        CONSTRUCTOR
    // ============================================================

    /**
     * @notice Initialize the test contract
     * @param _llmService Address of the LLM service contract
     */
    constructor(address _llmService) {
        require(_llmService != address(0), "LLMTest: invalid service address");

        owner = msg.sender;
        llmService = ILLMService(_llmService);
    }

    // ============================================================
    //                      ADMIN FUNCTIONS
    // ============================================================

    /**
     * @notice Update the LLM service contract address
     * @param _llmService New service address
     */
    function setLLMServiceAddress(address _llmService) external onlyOwner {
        require(_llmService != address(0), "LLMTest: invalid service address");
        llmService = ILLMService(_llmService);
        emit ServiceAddressUpdated(_llmService);
    }

    // ============================================================
    //                      MAIN FUNCTIONS
    // ============================================================

    /**
     * @notice Submit a new LLM request
     * @param configHash Hash of the config/prompt file
     * @param userInput The user's input string
     * @return requestId The LLM service request ID
     */
    function newRequest(bytes32 configHash, string calldata userInput) external payable returns (uint256 requestId) {
        // Build the input JSON string
        string memory input = string(abi.encodePacked(
            '{"user_input":"',
            userInput,
            '"}'
        ));

        // Call the LLM service
        // Parameters: platform, model, prompt, input, redundancy, returnContentWithinResultTag, storeResultOffchain, callback, args
        requestId = llmService.newRequest{value: msg.value}(
            bytes32(0),                    // platform (use from config)
            bytes32(0),                    // model (use from config)
            configHash,                    // prompt hash
            input,                         // JSON input
            1,                             // redundancy of 1
            true,                          // return content within result tag
            false,                         // don't store result off-chain
            "handleLLMResult",             // callback function
            abi.encode(msg.sender)         // encode sender address as args
        );

        emit RequestSubmitted(requestId, msg.sender, configHash);

        return requestId;
    }

    /**
     * @notice Callback function called by LLM service with the result
     * @param requestId The original request ID
     * @param result The LLM result string
     * @param args Encoded callback arguments (sender address)
     */
    function handleLLMResult(
        uint256 requestId,
        string calldata result,
        bytes calldata args
    ) external override {
        require(msg.sender == address(llmService), "LLMTest: only LLM service can call this");

        // Decode the sender address from args
        address sender = abi.decode(args, (address));

        // Store the result
        lastResult = result;

        emit LLMResult(requestId, sender, result);
    }

    // ============================================================
    //                    VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get the last result received
     * @return The last LLM result string
     */
    function getLastResult() external view returns (string memory) {
        return lastResult;
    }
}
