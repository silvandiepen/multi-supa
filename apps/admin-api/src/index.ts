import Fastify from 'fastify'
import fastifyCookie from '@fastify/cookie'
import fastifyJwt from '@fastify/jwt'
import fastifyStatic from '@fastify/static'
import path from 'node:path'
import fs from 'node:fs'
import { fileURLToPath } from 'node:url'
import bcrypt from 'bcryptjs'
import { spawn } from 'node:child_process'
import dotenv from 'dotenv'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

dotenv.config({ path: path.resolve(__dirname, '../../..', '.env') })

const ADMIN_HASH = process.env.ADMIN_BCRYPT_HASH || ''
const PORT = Number(process.env.ADMIN_PORT || 6010)
const JWT_SECRET = process.env.ADMIN_JWT_SECRET || ADMIN_HASH || 'change-me'
const ROOT = path.resolve(__dirname, '../../..')
const STATE_FILE = path.join(ROOT, 'state', 'projects.json')
const UI_DIR = path.resolve(ROOT, 'apps', 'admin-ui', 'dist')

const app = Fastify({ logger: true })

await app.register(fastifyCookie)
await app.register(fastifyJwt, { secret: JWT_SECRET, cookie: { cookieName: 'msession', signed: false } })

// Static admin UI
if (fs.existsSync(UI_DIR)) {
  await app.register(fastifyStatic, { root: UI_DIR, prefix: '/' })
}

app.decorate('auth', async (request: any, reply: any) => {
  try {
    await request.jwtVerify()
  } catch (err) {
    reply.code(401).send({ error: 'unauthorized' })
  }
})

app.post('/api/auth/login', async (req, reply) => {
  const body = (req.body || {}) as any
  const password = body.password || ''
  if (!ADMIN_HASH) return reply.code(500).send({ error: 'server not configured' })
  const ok = await bcrypt.compare(password, ADMIN_HASH)
  if (!ok) return reply.code(401).send({ error: 'invalid credentials' })
  const token = await reply.jwtSign({ ok: true }, { expiresIn: '7d' })
  reply.setCookie('msession', token, { httpOnly: true, sameSite: 'lax', path: '/', secure: true })
  return { ok: true }
})

app.get('/api/health', async () => ({ ok: true }))

function readState() {
  try { return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')) } catch { return [] }
}
function writeState(data: any) { fs.writeFileSync(STATE_FILE, JSON.stringify(data, null, 2)) }

async function sh(cmd: string, args: string[], cwd?: string) {
  return new Promise<{ code: number, out: string, err: string }>((resolve) => {
    const child = spawn(cmd, args, { cwd, env: process.env })
    let out = '', err = ''
    child.stdout.on('data', (d) => { out += d.toString() })
    child.stderr.on('data', (d) => { err += d.toString() })
    child.on('close', (code) => resolve({ code: code ?? 0, out, err }))
  })
}

app.addHook('onRequest', async (req, reply) => {
  if (req.url.startsWith('/api/') && req.url !== '/api/auth/login') {
    // @ts-ignore
    await (app as any).auth(req, reply)
  }
})

app.get('/api/projects', async () => {
  const items = readState()
  return items
})

app.post('/api/projects', async (req, reply) => {
  const body = (req.body || {}) as any
  const name = (body.name || '').trim()
  if (!name.match(/^[a-zA-Z0-9-]+$/)) return reply.code(400).send({ error: 'invalid name' })
  const { code, err } = await sh('bash', [path.join(ROOT, 'scripts', 'create-project.sh'), name], ROOT)
  if (code !== 0) return reply.code(500).send({ error: 'create failed', detail: err })
  return { ok: true }
})

app.post('/api/projects/:name/start', async (req, reply) => {
  const name = (req.params as any).name
  const items = readState()
  const p = items.find((x: any) => x.name === name)
  if (!p) return reply.code(404).send({ error: 'not found' })
  const { code, err } = await sh('bash', ['-lc', `cd ${p.path} && supabase start`])
  if (code !== 0) return reply.code(500).send({ error: 'start failed', detail: err })
  return { ok: true }
})

app.post('/api/projects/:name/stop', async (req, reply) => {
  const name = (req.params as any).name
  const items = readState()
  const p = items.find((x: any) => x.name === name)
  if (!p) return reply.code(404).send({ error: 'not found' })
  const { code, err } = await sh('bash', ['-lc', `cd ${p.path} && supabase stop`])
  if (code !== 0) return reply.code(500).send({ error: 'stop failed', detail: err })
  return { ok: true }
})

app.delete('/api/projects/:name', async (req, reply) => {
  const name = (req.params as any).name
  const purge = (req.query as any).purge ? ['--purge'] : []
  const args = [path.join(ROOT, 'scripts', 'destroy-project.sh'), name, ...purge]
  const { code, err } = await sh('bash', args, ROOT)
  if (code !== 0) return reply.code(500).send({ error: 'destroy failed', detail: err })
  return { ok: true }
})

app.post('/api/projects/:name/backup', async (req, reply) => {
  const name = (req.params as any).name
  const { code, err } = await sh('bash', [path.join(ROOT, 'scripts', 'backup-now.sh'), name], ROOT)
  if (code !== 0) return reply.code(500).send({ error: 'backup failed', detail: err })
  return { ok: true }
})

app.get('/api/projects/:name/logs/backup', async (req, reply) => {
  const name = (req.params as any).name
  const file = path.join('/var/log/supabase-backup', `${name}.log`)
  if (!fs.existsSync(file)) return reply.code(404).send({ error: 'no log' })
  const txt = fs.readFileSync(file, 'utf8')
  reply.type('text/plain').send(txt)
})

// SPA fallback
app.setNotFoundHandler((req, reply) => {
  const p = path.join(UI_DIR, 'index.html')
  if (fs.existsSync(p)) reply.type('text/html').send(fs.readFileSync(p))
  else reply.code(404).send({ error: 'not found' })
})

app.listen({ host: '127.0.0.1', port: PORT }, (err, address) => {
  if (err) { app.log.error(err); process.exit(1) }
  app.log.info(`admin-api listening on ${address}`)
})

