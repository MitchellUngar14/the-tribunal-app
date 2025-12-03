require('dotenv').config(); // Load environment variables from .env file

const express = require('express');
const cors = require('cors');
const path = require('path');
const fs = require('fs/promises'); // Use fs.promises for async file operations
const { GoogleGenerativeAI, HarmBlockThreshold, HarmCategory } = require('@google/generative-ai');

// TODO: Set your TRIBUNAL_API_KEY environment variable
const TRIBUNAL_API_KEY = process.env.TRIBUNAL_API_KEY; 

if (!TRIBUNAL_API_KEY) {
  console.error('TRIBUNAL_API_KEY environment variable is not set. AI responses will be unavailable.');
}

const genAI = new GoogleGenerativeAI(TRIBUNAL_API_KEY);
// model will be initialized dynamically based on user selection
let currentGenerativeModel; 

let agentDefinitions = []; // To store loaded agent definitions

async function loadAgentDefinitions() {
  const agentsPath = path.join(__dirname, '..', 'agents');
  console.log(`Attempting to load agent definitions from: ${agentsPath}`);
  try {
    const files = await fs.readdir(agentsPath);
    console.log(`Files found in agents directory: ${files}`);
    const agentFiles = files.filter(file => file.endsWith('.md'));

    for (const file of agentFiles) {
      const filePath = path.join(agentsPath, file);
      const content = await fs.readFile(filePath, 'utf8');

      const nameMatch = content.match(/# Agent: (.*)/);
      const personalityRoleMatch = content.match(/## Personality & Role\s*[\r\n]+([\s\S]*?)[\r\n]+## Core Prompt/); 
      const corePromptMatch = content.match(/## Core Prompt\s*[\r\n]+([\s\S]*)/); // Revised regex for core prompt
      const categoryMatch = content.match(/Category: (.*)/);


      if (nameMatch && corePromptMatch) {
        const name = nameMatch[1].trim();
        const personalityRole = personalityRoleMatch ? personalityRoleMatch[1].trim() : 'No personality/role defined.';
        const corePrompt = corePromptMatch[1].trim();
        const category = categoryMatch ? categoryMatch[1].trim() : 'Uncategorized'; // Default to Uncategorized
        agentDefinitions.push({ name, personalityRole, corePrompt, category });
      } else {
        console.warn(`Could not parse agent definition from ${file}`);
      }
    }
    console.log(`Loaded ${agentDefinitions.length} agent definitions.`);
  } catch (error) {
    console.error('Error loading agent definitions:', error);
  }
}




const app = express();
const port = 3001; // Backend will run on port 3001

const whitelist = ['http://localhost:3000', process.env.FRONTEND_URL].filter(Boolean); // Add your deployed frontend URL to environment variables
const corsOptions = {
  origin: function (origin, callback) {
    if (whitelist.indexOf(origin) !== -1 || !origin) {
      callback(null, true);
    } else {
      callback(new Error('Not allowed by CORS'));
    }
  },
};

app.use(cors(corsOptions)); // Enable CORS with options
app.use(express.json()); // Enable JSON body parsing

async function invokeAgent(agent, userQuestion, generativeModel, sharedContext = '', isRefinement = false) {
  let prompt = `You are an AI agent named "${agent.name}" with the following persona:\n\n${agent.personalityRole}\n\nYour core directive is: "${agent.corePrompt}".\n\n`;

  if (isRefinement && sharedContext) {
    prompt += `The user's original question was: "${userQuestion}".\n\n`;
    prompt += `Here are the current responses from other specialists in the Tribunal (including potentially your own previous response). Please review this context:\n\n---\n${sharedContext}\n---\n\n`;
    prompt += `Based on this shared context, refine your previous response or provide a new, more comprehensive and collaborative response to the original question, focusing on integrating with other specialists' input. Ensure your response still aligns with your core directive.`;
  } else {
    prompt += `Based on your expertise, please provide a very concise initial summary of your thoughts on the user's question (max 100 words), relevant to your specialization:\n\n"${userQuestion}"`;
  }

  // Basic token limit management (adjust as needed)
  const MAX_PROMPT_LENGTH = 3000; // Roughly 3000 characters to stay within common token limits
  if (prompt.length > MAX_PROMPT_LENGTH) {
    prompt = prompt.substring(0, MAX_PROMPT_LENGTH) + '... (truncated due to length)';
    console.warn(`Prompt for ${agent.name} truncated.`);
  }

  const MAX_RETRIES = 3;
  const RETRY_DELAY_MS = 100; // Base delay for exponential backoff

  for (let i = 0; i < MAX_RETRIES; i++) {
    try {
      const result = await generativeModel.generateContent({
        contents: [{ role: 'user', parts: [{ text: prompt }] }],
        safetySettings: [
          {
            category: HarmCategory.HARM_CATEGORY_HARASSMENT,
            threshold: HarmBlockThreshold.BLOCK_NONE,
          },
          {
            category: HarmCategory.HARM_CATEGORY_HATE_SPEECH,
            threshold: HarmBlockThreshold.BLOCK_NONE,
          },
          {
            category: HarmCategory.HARM_CATEGORY_SEXUALLY_EXPLICIT,
            threshold: HarmBlockThreshold.BLOCK_NONE,
          },
          {
            category: HarmCategory.HARM_CATEGORY_DANGEROUS_CONTENT,
            threshold: HarmBlockThreshold.BLOCK_NONE,
          },
        ],
      });
      const response = result.response;
      return response.text();
    } catch (error) {
      // Only retry for 503 Service Unavailable errors
      if (error.status === 503 && i < MAX_RETRIES - 1) {
        const delay = RETRY_DELAY_MS * Math.pow(2, i); // Exponential backoff
        console.warn(`Retrying agent ${agent.name} after ${delay}ms due to 503 Service Unavailable. Attempt ${i + 1}/${MAX_RETRIES}`);
        await new Promise(resolve => setTimeout(resolve, delay));
      } else {
        console.error(`Error invoking agent ${agent.name}:`, error);
        // If an agent errors out, return a generic error message
        return `Error: Could not generate response for ${agent.name}. (Check backend logs)`;
      }
    }
  }
  // If all retries fail
  return `Error: Could not generate response for ${agent.name} after multiple retries. (Check backend logs)`;
}

// Endpoint for Tribunal chat
app.post('/api/tribunal-chat', async (req, res) => {
  const userQuestion = req.body.question;
  const selectedAgentsNames = req.body.selectedAgents || [];
  const selectedModelName = req.body.selectedModel; // Get selected model name from request body

  if (!userQuestion) {
    return res.status(400).json({ error: 'Question is required.' });
  }
  if (selectedAgentsNames.length === 0) {
    return res.json({ responses: [{ agent: 'System', text: 'No agents selected to respond.' }] });
  }
  if (!selectedModelName) {
    return res.status(400).json({ error: 'Generative model is required.' });
  }

  // Initialize the model with the selected name
  currentGenerativeModel = genAI.getGenerativeModel({ model: selectedModelName });

  console.log('Received question:', userQuestion);
  console.log('Selected agents:', selectedAgentsNames);
  console.log('Selected model:', selectedModelName);

  const agentsToInvoke = agentDefinitions.filter(
    agent => selectedAgentsNames.includes(agent.name) && agent.name !== 'General Project Manager'
  );

  const refinementRounds = 2; // Number of times agents refine their responses
  let currentResponses = new Map(); // Map agentName to its current response

  // --- Initial Response Generation ---
  const initialResponsesArray = await Promise.all(
    agentsToInvoke.map(async (agent) => {
      const responseText = await invokeAgent(agent, userQuestion, currentGenerativeModel, '', false);
      currentResponses.set(agent.name, responseText);
      return { agent: agent.name, text: responseText, round: 0 };
    })
  );

  // --- Iterative Refinement Loop ---
  let allRoundResponses = [...initialResponsesArray]; // To keep track of responses per round
  for (let round = 1; round <= refinementRounds; round++) {
    console.log(`--- Refinement Round ${round} ---`);
    const MAX_AGENT_RESPONSE_LENGTH_FOR_CONTEXT = 500; // Characters

    const sharedContext = Array.from(currentResponses.entries())
      .map(([agentName, text]) => {
        const truncatedText = text.length > MAX_AGENT_RESPONSE_LENGTH_FOR_CONTEXT 
          ? text.substring(0, MAX_AGENT_RESPONSE_LENGTH_FOR_CONTEXT) + '... (truncated)'
          : text;
        return `${agentName}:\n${truncatedText}`;
      })
      .join('\n\n');

    const nextRoundResponses = await Promise.all(
      agentsToInvoke.map(async (agent) => {
        const responseText = await invokeAgent(agent, userQuestion, currentGenerativeModel, sharedContext, true);
        currentResponses.set(agent.name, responseText); // Update response for next round
        return { agent: agent.name, text: responseText, round: round };
      })
    );
    allRoundResponses.push(...nextRoundResponses);
  }

  // Filter to get only the final responses for each agent after refinement rounds
  const finalAgentResponses = Array.from(currentResponses.entries()).map(([agentName, text]) => ({
    agent: agentName,
    text: text,
  }));

  // Identify the General Project Manager
  const generalProjectManager = agentDefinitions.find(
    (agent) => agent.name === 'General Project Manager'
  );

  if (!generalProjectManager) {
    return res.status(500).json({
      error: 'General Project Manager agent not found in definitions.',
    });
  }

  // Construct context for the General Project Manager
  const synthesisContext = `User's original question: "${userQuestion}"\n\n` +
    `Here are the refined responses from the specialist agents. These might be summarized or refined versions of their initial thoughts, and your task is to take these and *expand* upon them to form a single, cohesive, and actionable plan or summary that addresses the user's original question, integrating all relevant insights from the specialists.`;

  console.log('Invoking General Project Manager for final synthesis...');
  const finalSummary = await invokeAgent(
    generalProjectManager,
    userQuestion,
    currentGenerativeModel,
    synthesisContext,
    true // Treat as a refinement round for the GPM
  );

  res.json({
    responses: [
      ...finalAgentResponses, // Include all individual agent responses
      { agent: 'The Tribunal', text: finalSummary, isSummary: true }, // Mark the summary explicitly
    ],
  });
});

// Endpoint to list agents (for potential future use or debugging)
app.get('/api/agents', async (req, res) => {
  res.json({ agents: agentDefinitions });
});

// Endpoint to generate a context file from Tribunal's recommendation
app.post('/api/generate-context-file', async (req, res) => {
  const { content } = req.body;
  if (!content) {
    return res.status(400).json({ error: 'Content is required to generate a context file.' });
  }

  const tribunalPlansDir = path.join(__dirname, '..', 'tribunal_plans');
  
  try {
    // Ensure the directory exists
    await fs.mkdir(tribunalPlansDir, { recursive: true });

    // Generate a unique filename using a timestamp
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-') ;
    const filename = `Tribunal_Plan_${timestamp}.md`;
    const filePath = path.join(tribunalPlansDir, filename);

    await fs.writeFile(filePath, content, 'utf8');
    console.log(`Context file created: ${filePath}`);
    res.json({ message: 'Context file generated successfully.', filePath: filePath });
  } catch (error) {
    console.error('Error generating context file:', error);
    res.status(500).json({ error: 'Failed to generate context file.' });
  }
});


module.exports = app;

// Start the server only if not in a Vercel environment
if (!process.env.VERCEL_ENV) {
  (async () => {
    console.log('Local server starting: Awaiting agent definitions...');
    await loadAgentDefinitions(); // Await here for local execution
    console.log('Local server starting: Agent definitions loaded.');
    app.listen(port, () => {
      console.log(`Tribunal Backend listening at http://localhost:${port}`);
    });
  })();
} else {
  // For Vercel, ensure loadAgentDefinitions is called before module.exports is fully evaluated
  // This top-level await will run once during Vercel's build process
  (async () => {
    console.log('Vercel environment: Awaiting agent definitions for serverless function...');
    await loadAgentDefinitions();
    console.log('Vercel environment: Agent definitions loaded for serverless function.');
  })();
}
