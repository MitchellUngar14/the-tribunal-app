import React, { useState, useEffect, useMemo } from 'react';
import './App.css';
import Sidebar from './Sidebar'; // Import the Sidebar component
import { marked } from 'marked'; // Import marked
import DOMPurify from 'dompurify'; // Import DOMPurify
import Prism from 'prismjs'; // Import prismjs
import 'prismjs/themes/prism-tomorrow.css'; // Import a prism theme

const backendUrl = process.env.REACT_APP_BACKEND_URL || 'http://localhost:3001';

// Helper function to convert agent name to CSS class name
const agentNameToClassName = (name) => {
  if (!name) return '';
  return name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
};

// Configure marked to use Prism for syntax highlighting
marked.setOptions({
  highlight: function(code, lang) {
    if (Prism.languages[lang]) {
      return Prism.highlight(code, Prism.languages[lang], lang);
    } else {
      return code;
    }
  },
});


function App() {
  const [messages, setMessages] = useState([]);
  const [input, setInput] = useState('');
  const [loading, setLoading] = useState(false);
  const [isSidebarOpen, setIsSidebarOpen] = useState(false); // State for sidebar visibility, default to closed
  const [allAgents, setAllAgents] = useState([]); // State to store all available agents (with categories)
  const [selectedAgents, setSelectedAgents] = useState([]); // State for currently selected agents
  const [showIndividualAgentResponses, setShowIndividualAgentResponses] = useState(true); // New state for toggling individual responses
  const [availableModels, setAvailableModels] = useState([]); // New state for available Gemini models
  const [selectedModel, setSelectedModel] = useState(''); // New state for the currently selected Gemini model

  // Fetch agents and models from backend on component mount
  useEffect(() => {
    const fetchAgents = async () => {
      setAllAgents([]); // Clear agents before fetching
      setSelectedAgents([]); // Clear selected agents before fetching
      try {
        // Fetch agents
        const agentsResponse = await fetch(`${backendUrl}/api/agents`);
        if (!agentsResponse.ok) {
          throw new Error(`HTTP error! status: ${agentsResponse.status}`);
        }
        const agentsData = await agentsResponse.json(); // agentsData.agents should now be objects with { name, category }
        setAllAgents(agentsData.agents);
        // By default, select all agents
        setSelectedAgents(agentsData.agents.map(agent => agent.name));

        // Hardcode available models
        const hardcodedModels = [
          { name: 'gemini-3-pro-preview', displayName: 'Gemini 3 Pro Preview' },
          { name: 'gemini-2.5-pro', displayName: 'Gemini 2.5 Pro' },
          { name: 'gemini-2.5-flash', displayName: 'Gemini 2.5 Flash' },
        ];
        setAvailableModels(hardcodedModels);
        // Set a default model
        setSelectedModel('gemini-2.5-pro'); // Default to gemini-2.5-pro
      } catch (error) {
        console.error('Error fetching initial data (agents or models):', error);
      }
    };
    fetchAgents();
  }, []); // Empty dependency array means this runs once on mount

  // Highlight all code blocks whenever messages change
  useEffect(() => {
    Prism.highlightAll();
  }, [messages, showIndividualAgentResponses]);
  
  const toggleSidebar = () => {
    setIsSidebarOpen(!isSidebarOpen);
  };


  // Function to handle agent checkbox changes
  const handleAgentSelection = (agentName, isChecked) => {
    if (isChecked) {
      setSelectedAgents((prev) => [...prev, agentName]);
    } else {
      setSelectedAgents((prev) => prev.filter((name) => name !== agentName));
    }
  };

  const handleSelectAll = (agentsInCategory, shouldSelect) => {
    if (shouldSelect) {
      const agentsToSelect = agentsInCategory.filter(
        (name) => !selectedAgents.includes(name)
      );
      setSelectedAgents((prev) => [...prev, ...agentsToSelect]);
    } else {
      setSelectedAgents((prev) =>
        prev.filter((name) => !agentsInCategory.includes(name))
      );
    }
  };

  const lastTribunalMessage = useMemo(() => {
    // Find the last message where agentName is 'The Tribunal'
    for (let i = messages.length - 1; i >= 0; i--) {
      if (messages[i].agentName === 'The Tribunal') {
        return messages[i];
      }
    }
    return null;
  }, [messages]);

  const handleGenerateContextFile = (tribunalResponseText) => {
    try {
      const filename = `Tribunal_Recommendation_${new Date().toISOString().replace(/[:.]/g, '-')}.md`;
      const blob = new Blob([tribunalResponseText], { type: 'text/markdown' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
      alert(`Context file "${filename}" downloaded to your device.`);
    } catch (error) {
      console.error('Error generating or downloading context file:', error);
      alert('Error generating or downloading context file. Check console for details.');
    }
  };

  const handleSend = async () => {
    if (input.trim()) {
      const userMessage = { text: input, sender: 'user' };
      setMessages((prevMessages) => [...prevMessages, userMessage]);
      setInput('');
      setLoading(true);

      try {
        const response = await fetch(`${backendUrl}/api/tribunal-chat`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ question: userMessage.text, selectedAgents, selectedModel }), // Send selectedModel
        });

        if (!response.ok) {
          throw new Error(`HTTP error! status: ${response.status}`);
        }

        const data = await response.json();
        // Assuming data.responses is an array of { agent: string, text: string, isSummary?: boolean }
        const allNewMessages = data.responses.map(res => ({
          text: `**${res.agent}:** ${res.text}`,
          sender: 'agent',
          agentName: res.agent,
          isSummary: res.isSummary || false, // Capture isSummary flag
        }));
        setMessages((prevMessages) => [...prevMessages, ...allNewMessages]);
      } catch (error) {
        console.error('Error sending message:', error);
        setMessages((prevMessages) => [
          ...prevMessages,
          { text: 'Error: Could not get a response from the Tribunal.', sender: 'agent' },
        ]);
      } finally {
        setLoading(false);
      }
    }
  };

  return (
    <div className="App">
      <Sidebar
        isOpen={isSidebarOpen}
        toggleSidebar={toggleSidebar}
        allAgents={allAgents}
        selectedAgents={selectedAgents}
        handleAgentSelection={handleAgentSelection}
        handleSelectAll={handleSelectAll}
      /> {/* Integrate Sidebar */}

      <div className={`main-content ${!isSidebarOpen ? 'sidebar-closed' : ''}`}>
        <header className="app-header">
          <button className="sidebar-toggle-btn" onClick={toggleSidebar}>
            ☰ {/* Hamburger icon */}
          </button>
          <h1>The Tribunal</h1>
          <div className="toggle-individual-responses">
            <label>
              <input
                type="checkbox"
                checked={showIndividualAgentResponses}
                onChange={(e) => setShowIndividualAgentResponses(e.target.checked)}
              />
              Show individual responses
            </label>
          </div>
          <div className="model-selector">
            <label htmlFor="model-select">Model:</label>
            <select
              id="model-select"
              value={selectedModel}
              onChange={(e) => setSelectedModel(e.target.value)}
              disabled={loading}
            >
              {availableModels.map((model) => (
                <option key={model.name} value={model.name}>
                  {model.displayName || model.name}
                </option>
              ))}
            </select>
          </div>
        </header>
        <div className="chat-container">
          <div className="messages-display">
            {messages.map((msg, index) => {
              // Conditionally render individual agent responses
              if (!showIndividualAgentResponses && msg.agentName !== 'The Tribunal' && msg.sender === 'agent' && !msg.isSummary) {
                return null; // Don't render individual agent messages if toggle is off, but always show summary
              }
              return (
                <div
                  key={index}
                  className={`message ${msg.sender} ${msg.sender === 'agent' ? agentNameToClassName(msg.agentName) : ''}`}
                >
                  <div dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(marked.parse(msg.text)) }} />
                </div>
              );
            })}
            {loading && (
              <div className="message agent loading">
                Thinking...
              </div>
            )}
          </div>
          <div className="input-area">
            <input
              type="text"
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyPress={(e) => {
                if (e.key === 'Enter' && !loading) {
                  handleSend();
                }
              }}
              placeholder={loading ? "Waiting for response..." : "Type your question..."}
              disabled={loading}
            />
                                <button onClick={handleSend} disabled={loading}>
                                  {loading ? 'Sending...' : 'Send'}
                                </button>
                              </div>
                              {lastTribunalMessage && (
                                  <div className="generate-context-area">
                                      <button onClick={() => handleGenerateContextFile(lastTribunalMessage.text)}>Generate Context File</button>
                                  </div>
                              )}
                            </div> {/* Closing tag for chat-container */}      </div> {/* Closing tag for main-content */}
    </div>
  );
}
export default App;