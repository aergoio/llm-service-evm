const axios = require('axios');
require('dotenv').config();

// API keys from environment variables
const OPENAI_API_KEY = process.env.OPENAI_API_KEY;
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY;
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
const GROK_API_KEY = process.env.GROK_API_KEY;
const GROQ_API_KEY = process.env.GROQ_API_KEY;
const DEEPSEEK_API_KEY = process.env.DEEPSEEK_API_KEY;
const QWEN_API_KEY = process.env.QWEN_API_KEY;
const MOONSHOT_API_KEY = process.env.MOONSHOT_API_KEY;
const ZAI_API_KEY = process.env.ZAI_API_KEY;
const PERPLEXITY_API_KEY = process.env.PERPLEXITY_API_KEY;

/**
 * Process an LLM request based on the specified platform and model
 * @param {string} platform - The LLM platform (openai or anthropic)
 * @param {string} model - The model name to use
 * @param {string} prompt - The user prompt
 * @returns {Promise<string>} - The LLM response
 */
async function process_llm_request(platform, model, prompt) {
  console.log(`Processing ${platform} request with model ${model}`);

  try {
    switch (platform.toLowerCase()) {
      case 'openai':
        return await process_openai_request(model, prompt);
      case 'anthropic':
        return await process_anthropic_request(model, prompt);
      case 'gemini':
        return await process_gemini_request(model, prompt);
      case 'grok':
        return await process_grok_request(model, prompt);
      case 'groq':
        return await process_groq_request(model, prompt);
      case 'deepseek':
        return await process_deepseek_request(model, prompt);
      case 'qwen':
        return await process_qwen_request(model, prompt);
      case 'kimi':
        return await process_kimi_request(model, prompt);
      case 'perplexity':
        return await process_perplexity_request(model, prompt);
      case 'zai':
      case 'zhipu':
        return await process_zai_request(model, prompt);
      default:
        throw new Error(`Unsupported platform: ${platform}`);
    }
  } catch (error) {
    console.error(`Error in process_llm_request: ${error.message}`);
    if (error.response) {
      console.error('API response:', error.response.data);
    }
    throw error;
  }
}

/**
 * Process a request using OpenAI's API
 * @param {string} model - The OpenAI model to use (e.g., "gpt-4", "gpt-3.5-turbo")
 * @param {string} prompt - The user prompt
 * @returns {Promise<string>} - The model's response
 */
async function process_openai_request(model, prompt) {
  if (!OPENAI_API_KEY) {
    throw new Error('OPENAI_API_KEY environment variable is not set');
  }

  const headers = {
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${OPENAI_API_KEY}`
  };

  const makeRequest = async (includeTemperature) => {
    const requestBody = {
      model: model,
      messages: [{ role: 'user', content: prompt }],
    };
    if (includeTemperature) {
      requestBody.temperature = 0.0;
    }
    return axios.post('https://api.openai.com/v1/chat/completions', requestBody, { headers });
  };

  try {
    // Try with temperature first
    const response = await makeRequest(true);
    return response.data.choices[0].message.content.trim();
  } catch (error) {
    // If temperature is unsupported, retry without it
    if (error.response?.data?.error?.code === 'unsupported_value' &&
        error.response?.data?.error?.param === 'temperature') {
      console.log(`Model ${model} does not support temperature parameter, retrying without it`);
      const response = await makeRequest(false);
      return response.data.choices[0].message.content.trim();
    }
    throw error;
  }
}

/**
 * Process a request using Anthropic's API
 * @param {string} model - The Anthropic model to use (e.g., "claude-3-opus", "claude-3-sonnet")
 * @param {string} prompt - The user prompt
 * @returns {Promise<string>} - The model's response
 */
async function process_anthropic_request(model, prompt) {
  if (!ANTHROPIC_API_KEY) {
    throw new Error('ANTHROPIC_API_KEY environment variable is not set');
  }

  const response = await axios.post(
    'https://api.anthropic.com/v1/messages',
    {
      model: model,
      messages: [{ role: 'user', content: prompt }],
      temperature: 0.0,
      max_tokens: 4096,
    },
    {
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': ANTHROPIC_API_KEY,
        'anthropic-version': '2023-06-01'
      }
    }
  );

  return response.data.content[0].text;
}

/**
 * Process a request using Google's Gemini API
 * @param {string} model - The Gemini model to use (e.g., "gemini-pro")
 * @param {string} prompt - The user prompt
 * @returns {Promise<string>} - The model's response
 */
async function process_gemini_request(model, prompt) {
  if (!GEMINI_API_KEY) {
    throw new Error('GEMINI_API_KEY environment variable is not set');
  }

  const apiKey = GEMINI_API_KEY;
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`;

  const response = await axios.post(
    url,
    {
      contents: [{
        parts: [{
          text: prompt
        }]
      }],
      generationConfig: {
        temperature: 0.0,
        maxOutputTokens: 4096
      }
    },
    {
      headers: {
        'Content-Type': 'application/json',
      }
    }
  );

  // Defensive check for response structure
  if (response.data && response.data.candidates && response.data.candidates[0] &&
      response.data.candidates[0].content && response.data.candidates[0].content.parts &&
      response.data.candidates[0].content.parts[0] && response.data.candidates[0].content.parts[0].text) {
    return response.data.candidates[0].content.parts[0].text.trim();
  } else {
    console.error('Unexpected Gemini API response structure:', response.data);
    throw new Error('Failed to parse Gemini API response.');
  }
}

/**
 * Process a request using Grok's API
 * @param {string} model - The Grok model to use (e.g., "grok-1")
 * @param {string} prompt - The user prompt
 * @returns {Promise<string>} - The model's response
 */
async function process_grok_request(model, prompt) {
  if (!GROK_API_KEY) {
    throw new Error('GROK_API_KEY environment variable is not set');
  }

  const response = await axios.post(
    'https://api.x.ai/v1/chat/completions',
    {
      model: model,
      messages: [{ role: 'user', content: prompt }],
      temperature: 0,
      max_tokens: 4096,
      stream: false
    },
    {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${GROK_API_KEY}`
      }
    }
  );

  return response.data.choices[0].message.content.trim();
}

/**
 * Process a request using DeepSeek's API
 * @param {string} model - The DeepSeek model to use (e.g., "deepseek-chat")
 * @param {string} prompt - The user prompt
 * @returns {Promise<string>} - The model's response
 */
async function process_deepseek_request(model, prompt) {
  if (!DEEPSEEK_API_KEY) {
    throw new Error('DEEPSEEK_API_KEY environment variable is not set');
  }

  const response = await axios.post(
    'https://api.deepseek.com/v1/chat/completions',
    {
      model: model,
      messages: [{ role: 'user', content: prompt }],
      temperature: 0.0,
      max_tokens: 4096,
    },
    {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${DEEPSEEK_API_KEY}`
      }
    }
  );

  return response.data.choices[0].message.content.trim();
}

/**
 * Process a request using Qwen's API
 * @param {string} model - The Qwen model to use (e.g., "qwen-turbo", "qwen-plus")
 * @param {string} prompt - The user prompt
 * @returns {Promise<string>} - The model's response
 */
async function process_qwen_request(model, prompt) {
  if (!QWEN_API_KEY) {
    throw new Error('QWEN_API_KEY environment variable is not set');
  }

  const response = await axios.post(
    'https://dashscope.aliyuncs.com/api/v1/services/aigc/text-generation/generation',
    {
      model: model,
      input: {
        messages: [{ role: 'user', content: prompt }]
      },
      parameters: {
        temperature: 0.0,
        max_tokens: 4096
      }
    },
    {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${QWEN_API_KEY}`
      }
    }
  );

  return response.data.output.text.trim();
}

/**
 * Process a request using Groq's API
 * @param {string} model - The Groq model to use (e.g., "llama3-8b-8192", "mixtral-8x7b-32768")
 * @param {string} prompt - The user prompt
 * @returns {Promise<string>} - The model's response
 */
async function process_groq_request(model, prompt) {
  if (!GROQ_API_KEY) {
    throw new Error('GROQ_API_KEY environment variable is not set');
  }

  const response = await axios.post(
    'https://api.groq.com/openai/v1/chat/completions',
    {
      model: model,
      messages: [{ role: 'user', content: prompt }],
      temperature: 0.0,
      max_tokens: 4096,
    },
    {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${GROQ_API_KEY}`
      }
    }
  );

  return response.data.choices[0].message.content.trim();
}

/**
 * Process a request using Kimi (Moonshot) API
 * @param {string} model - The Kimi model to use (e.g., "kimi-thinking-preview")
 * @param {string} prompt - The user prompt
 * @returns {Promise<string>} - The model's response
 */
async function process_kimi_request(model, prompt) {
  if (!MOONSHOT_API_KEY) {
    throw new Error('MOONSHOT_API_KEY environment variable is not set');
  }

  const response = await axios.post(
    'https://api.moonshot.cn/v1/chat/completions',
    {
      model: model,
      messages: [{ role: 'user', content: prompt }],
      temperature: 0.0,
    },
    {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${MOONSHOT_API_KEY}`
      }
    }
  );

  return response.data.choices[0].message.content.trim();
}

/**
 * Process a request using Z.ai (Zhipu) GLM API
 * @param {string} model - The GLM model to use (e.g., "GLM-4.6", "GLM-4.5-Air")
 * @param {string} prompt - The user prompt
 * @returns {Promise<string>} - The model's response
 */
async function process_zai_request(model, prompt) {
  if (!ZAI_API_KEY) {
    throw new Error('ZAI_API_KEY environment variable is not set');
  }

  const response = await axios.post(
    'https://api.z.ai/api/paas/v4/chat/completions',
    {
      model: model,
      messages: [{ role: 'user', content: prompt }],
      temperature: 0.0,
      max_tokens: 4096,
    },
    {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${ZAI_API_KEY}`
      }
    }
  );

  return response.data.choices[0].message.content.trim();
}

/**
 * Process a request using Perplexity's API
 * @param {string} model - The Perplexity model to use (e.g., "sonar", "pplx-7b-chat")
 * @param {string} prompt - The user prompt
 * @returns {Promise<string>} - The model's response
 */
async function process_perplexity_request(model, prompt) {
  if (!PERPLEXITY_API_KEY) {
    throw new Error('PERPLEXITY_API_KEY environment variable is not set');
  }

  const response = await axios.post(
    'https://api.perplexity.ai/chat/completions',
    {
      model: model,
      messages: [{ role: 'user', content: prompt }],
      temperature: 0.0,
      max_tokens: 4096,
    },
    {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${PERPLEXITY_API_KEY}`
      }
    }
  );

  return response.data.choices[0].message.content.trim();
}

module.exports = {
  process_llm_request
};
