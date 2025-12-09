import React, { useMemo } from 'react';
import './Sidebar.css';

function Sidebar({ isOpen, toggleSidebar, allAgents, selectedAgents, handleAgentSelection, handleSelectAll }) {
  // Group agents by category
  const categorizedAgents = useMemo(() => {
    return allAgents.reduce((acc, agent) => {
      const { category, name } = agent;
      if (!acc[category]) {
        acc[category] = [];
      }
      acc[category].push(name);
      return acc;
    }, {});
  }, [allAgents]);

  return (
    <div className={`sidebar ${isOpen ? 'open' : 'closed'}`}>
      <button className="close-sidebar-btn" onClick={toggleSidebar}>
        &times; {/* HTML entity for multiplication sign (a common close icon) */}
      </button>
      <div className="sidebar-content">
        <h2>Agents</h2>
        {Object.entries(categorizedAgents).map(([category, agents]) => (
          <div key={category} className="agent-category">
            <h3>{category}</h3>
            <div className="select-all-buttons">
              <button onClick={() => handleSelectAll(agents, true)}>All</button>
              <button onClick={() => handleSelectAll(agents, false)}>None</button>
            </div>
            <ul className="agent-list">
              {agents.map((agentName) => (
                <li key={agentName}>
                  <label>
                    <input
                      type="checkbox"
                      value={agentName}
                      checked={selectedAgents.includes(agentName)}
                      onChange={(e) => handleAgentSelection(agentName, e.target.checked)}
                    />
                    {agentName.replace(' Specialist', '')}
                  </label>
                </li>
              ))}
            </ul>
          </div>
        ))}
      </div>
    </div>
  );
}

export default Sidebar;