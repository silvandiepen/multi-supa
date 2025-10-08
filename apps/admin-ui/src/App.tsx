import React, { useEffect, useMemo, useState } from 'react'

type Project = {
  name: string
  apiPort: number
  dbPort: number
  studioPort: number
  createdAt: string
  enabled: boolean
  lastBackup: string | null
}

async function api<T>(path: string, opts: RequestInit = {}): Promise<T> {
  const res = await fetch(`/api${path}`, { credentials: 'include', ...opts, headers: { 'Content-Type': 'application/json', ...(opts.headers||{}) } })
  if (!res.ok) throw new Error(await res.text())
  return res.headers.get('content-type')?.includes('application/json') ? res.json() : (await res.text() as any)
}

function Login({ onOk }: { onOk: () => void }) {
  const [password, setPassword] = useState('')
  const [loading, setLoading] = useState(false)
  const [err, setErr] = useState('')
  return (
    <div className="h-screen flex items-center justify-center">
      <div className="card w-full max-w-sm">
        <h1 className="text-xl font-semibold mb-4">Admin Login</h1>
        <input className="input mb-3" type="password" placeholder="Password" value={password} onChange={e=>setPassword(e.target.value)} />
        <button className="btn w-full" disabled={loading} onClick={async()=>{
          setLoading(true); setErr('')
          try { await api('/auth/login', { method: 'POST', body: JSON.stringify({ password }) }); onOk() } catch (e:any) { setErr('Login failed') }
          setLoading(false)
        }}>Login</button>
        {err && <p className="text-red-600 text-sm mt-2">{err}</p>}
      </div>
    </div>
  )
}

function Dashboard() {
  const [projects, setProjects] = useState<Project[]|null>(null)
  const [name, setName] = useState('')
  const domain = useMemo(()=> (window.location.hostname.replace(/^db\./,'')||'<domain>'), [])
  const load = async()=> setProjects(await api<Project[]>('/projects'))
  useEffect(()=>{ load() }, [])
  return (
    <div className="max-w-5xl mx-auto p-6 space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">Projects</h1>
        <div className="flex gap-2">
          <input className="input" placeholder="new-project-name" value={name} onChange={e=>setName(e.target.value)} />
          <button className="btn" onClick={async()=>{ await api('/projects', { method: 'POST', body: JSON.stringify({ name }) }); setName(''); await load() }}>Create</button>
        </div>
      </div>

      <div className="grid grid-cols-1 gap-3">
        {(projects||[]).map(p => (
          <div key={p.name} className="card">
            <div className="flex items-center justify-between">
              <div>
                <div className="font-medium">{p.name}</div>
                <div className="text-sm text-gray-600">API: <a className="text-blue-600" href={`https://api.${domain}/${p.name}`} target="_blank">api.{domain}/{p.name}</a> · Studio: <a className="text-blue-600" href={`https://studio.${domain}/${p.name}`} target="_blank">studio.{domain}/{p.name}</a></div>
                <div className="text-xs text-gray-500">Ports: api {p.apiPort}, db {p.dbPort}, studio {p.studioPort} · Created {p.createdAt} · Last backup: {p.lastBackup||'-'}</div>
              </div>
              <div className="flex gap-2">
                <button className="btn" onClick={async()=>{ await api(`/projects/${p.name}/start`, { method:'POST' }); await load() }}>Start</button>
                <button className="btn" onClick={async()=>{ await api(`/projects/${p.name}/stop`, { method:'POST' }); await load() }}>Stop</button>
                <button className="btn" onClick={async()=>{ await api(`/projects/${p.name}/backup`, { method:'POST' }); }}>Backup</button>
                <button className="btn bg-red-600 hover:bg-red-700" onClick={async()=>{ if(confirm('Delete project?')) { await api(`/projects/${p.name}`, { method:'DELETE' }); await load() } }}>Delete</button>
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}

export default function App() {
  const [authed, setAuthed] = useState(false)
  useEffect(()=>{ fetch('/api/health',{credentials:'include'}).then(()=>setAuthed(true)).catch(()=>{}) },[])
  if (!authed) return <Login onOk={()=>setAuthed(true)} />
  return <Dashboard />
}

