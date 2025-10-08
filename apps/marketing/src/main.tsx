import React from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter, Link, Route, Routes } from 'react-router-dom'

function Layout({ children }: any) {
  return (
    <div style={{maxWidth:900, margin:'0 auto', padding:24}}>
      <header style={{display:'flex', gap:16, alignItems:'center', marginBottom:24}}>
        <h1 style={{fontSize:20, fontWeight:600}}>Multi Supa</h1>
        <nav style={{display:'flex', gap:12}}>
          <Link to="/">Home</Link>
          <Link to="/pricing">Pricing</Link>
          <Link to="/faq">FAQ</Link>
          <Link to="/contact">Contact</Link>
        </nav>
      </header>
      <main>{children}</main>
    </div>
  )
}

const Home = () => <Layout><h2>Self-host multiple Supabase projects</h2><p>Spin up, manage, and back up Supabase projects under one roof.</p></Layout>
const Pricing = () => <Layout><h2>Pricing</h2><p>Self-hosted. You pay your infra. This repo is free.</p></Layout>
const FAQ = () => <Layout><h2>FAQ</h2><p>Bring your Cloudflare R2 keys for backups. Caddy handles TLS.</p></Layout>
const Contact = () => <Layout><h2>Contact</h2><p>File issues on GitHub.</p></Layout>

createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Home/>} />
        <Route path="/pricing" element={<Pricing/>} />
        <Route path="/faq" element={<FAQ/>} />
        <Route path="/contact" element={<Contact/>} />
      </Routes>
    </BrowserRouter>
  </React.StrictMode>
)

