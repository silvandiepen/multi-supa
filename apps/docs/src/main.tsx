import React from 'react'
import { createRoot } from 'react-dom/client'

function App() {
  return (
    <div style={{maxWidth: 800, margin: '40px auto', fontFamily: 'sans-serif'}}>
      <h1>Multi Supa Docs (Placeholder)</h1>
      <p>Documentation coming soon. Focus is on the setup script and admin.</p>
      <ul>
        <li>Bootstrap the VPS with <code>scripts/bootstrap.sh</code></li>
        <li>Manage projects at <code>https://db.&lt;domain&gt;</code></li>
        <li>API paths under <code>https://api.&lt;domain&gt;/&lt;project&gt;</code></li>
        <li>Studio under <code>https://studio.&lt;domain&gt;/&lt;project&gt;</code></li>
      </ul>
    </div>
  )
}

createRoot(document.getElementById('root')!).render(<App />)

