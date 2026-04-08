// Smooth scroll
document.querySelectorAll('a[href^="#"]').forEach((a) => {
  a.addEventListener('click', (e) => {
    const target = document.querySelector(a.getAttribute('href'));
    if (target) {
      e.preventDefault();
      target.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  });
});

// Mobile nav
document.getElementById('navToggle').addEventListener('click', () => {
  document.getElementById('mainNav').classList.toggle('nav--open');
});

// Integration code tabs
const snippets = {
  1: {
    file: 'MyContract.sol',
    code: `import "./llm-service.sol";

contract MyContract is ILLMServiceCallback {
    ILLMService public aiService;

    constructor(address _aiService) {
        aiService = ILLMService(_aiService);
    }
}`,
  },
  2: {
    file: 'MyContract.sol',
    code: `function askAI(
    bytes32 configHash,
    string calldata userInput
) external payable {
    string memory input = string(abi.encodePacked(
        '{"user_input":"', userInput, '"}'
    ));

    aiService.newRequest{value: msg.value}(
        bytes32(0),          // platform (from config)
        bytes32(0),          // model (from config)
        configHash,          // SHA256 of your prompt
        input,               // JSON runtime values
        1,                   // redundancy (quorum = 1)
        true,                // extract <result> tags
        false,               // store on-chain
        "handleAIResult",    // your callback name
        abi.encode(msg.sender)
    );
}`,
  },
  3: {
    file: 'MyContract.sol',
    code: `function handleAIResult(
    uint256 requestId,
    string calldata result,
    bytes calldata args
) external override {
    require(
        msg.sender == address(aiService),
        "unauthorized"
    );

    address requester = abi.decode(args, (address));

    // result is the AI-generated string
    // e.g. "positive" / "negative" / a JSON blob
    emit AIResultReceived(requester, result);
}`,
  },
  4: {
    file: 'prompt.config',
    code: `model: anthropic/claude-sonnet-4-20250514
You are a helpful assistant that classifies
user sentiment in one word.

User message: {{user_input}}

Respond with your classification inside
<result></result> tags. Output only one word:
positive, negative, or neutral.`,
  },
};

document.querySelectorAll('.integrate-step').forEach((el) => {
  el.addEventListener('click', () => {
    document.querySelectorAll('.integrate-step').forEach((s) => s.classList.remove('active'));
    el.classList.add('active');
    const step = el.dataset.step;
    const s = snippets[step];
    document.getElementById('codeFilename').textContent = s.file;
    document.getElementById('codeContent').textContent = s.code;
  });
});
